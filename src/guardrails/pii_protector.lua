-- guardrails/pii_protector.lua — Tier-2 reversible PII tokenizer.
--
-- Request phase:
--   Calls Presidio /analyze to locate PII spans, replaces each unique value
--   with a token [MYRA-REDACT:SALT:N], and stores the reverse map in ctx.pii_token_map.
--   The upstream AI provider receives the tokenized body.
--
-- Response phase:
--   Finds tokens in ctx.response_body and replaces them with original values
--   before the response is sent to the client.
--
-- Token format: [MYRA-REDACT:SALT:N]
--   SALT = first 6 hex chars of ngx.md5(request_id .. ngx.now()) — per-request unique
--   N    = sequential counter starting at 1
--   Characters [, ], :, alphanumerics are valid inside JSON strings without escaping.
--
-- Same original value → same token within a request (deduplication).
-- Overlapping spans → highest-score span wins (greedy resolution).
-- Right-to-left replacement preserves byte offsets for earlier spans.
-- Plain-string restore avoids Lua magic-char issues with [ and ] in gsub patterns.
--
-- Known limitation: streaming responses are not buffered (ctx.response_body is nil).
-- The response-phase guardrail is skipped for streaming by guardrails_response.lua.
-- Tokens remain visible in streamed output. The LLM never saw real PII so security
-- is preserved, but UX is degraded.

local json      = require("utils.json")
local http_util = require("utils.http")

local M = {}

local DEFAULT_ANALYZER_URL    = "http://127.0.0.1:5002"
local DEFAULT_SCORE_THRESHOLD = 0.7
local DEFAULT_LANGUAGE        = "en"

-- Entity types known to produce high false positive rates on legitimate text.
-- Applied as defaults when entity_score_thresholds is not explicitly configured.
-- See benchmarks in tests/false_positives/ for measured FP rates.
local HIGH_FP_ENTITY_THRESHOLDS = {
    PERSON    = 0.9,
    LOCATION  = 0.9,
    DATE_TIME = 0.9,
    NRP       = 0.9,
}

-- Post-filter Presidio results through per-entity score thresholds.
-- Priority: explicit entity_score_thresholds config > HIGH_FP defaults > global threshold.
local function apply_entity_thresholds(entities, detector)
    local global = detector.score_threshold or DEFAULT_SCORE_THRESHOLD
    local per    = detector.entity_score_thresholds or {}

    local filtered = {}
    for _, e in ipairs(entities) do
        local et        = e.entity_type or e.type
        local threshold = per[et] or HIGH_FP_ENTITY_THRESHOLDS[et] or global
        if (e.score or 0) >= threshold then
            filtered[#filtered + 1] = e
        end
    end
    return filtered
end

-- ---------------------------------------------------------------------------
-- call_analyzer: POST to Presidio /analyze.
-- Returns array of {entity_type, start, end, score} (0-based char offsets), or nil, err.
-- Mirrors the call pattern in guardrails/presidio.lua.
-- ---------------------------------------------------------------------------
local function call_analyzer(text, detector)
    local url      = (detector.analyzer_url or DEFAULT_ANALYZER_URL) .. "/analyze"
    -- Connect and send are fast (local service). Read can be slow for large payloads
    -- because spaCy NLP processing scales with text length.
    -- timeout_ms (legacy) still works as a unified fallback.
    local read_ms  = detector.timeout_ms or 15000

    local payload = json.encode({
        text             = text,
        language         = detector.language or DEFAULT_LANGUAGE,
        entities         = detector.entities,
        score_threshold  = detector.score_threshold or DEFAULT_SCORE_THRESHOLD,
        allow_list       = detector.allow_list,
        allow_list_match = detector.allow_list_match,
    })

    local status, _, body, err = http_util.request({
        method              = "POST",
        url                 = url,
        headers             = { ["Content-Type"] = "application/json" },
        body                = payload,
        connect_timeout_ms  = 500,
        send_timeout_ms     = 2000,
        read_timeout_ms     = read_ms,
    })

    if err or not body then
        return nil, "analyzer request: " .. tostring(err)
    end
    if status ~= 200 then
        return nil, "analyzer http " .. tostring(status)
    end

    local result = json.decode(body)
    if not result then
        return nil, "analyzer parse"
    end
    return result
end

-- ---------------------------------------------------------------------------
-- build_exclusion_ranges: find the byte ranges occupied by system/assistant
-- message content in the raw JSON body so that entities detected within those
-- ranges can be dropped before tokenization.
--
-- Rationale: system and assistant messages are operator/model-controlled text,
-- not user-supplied data.  Tokenizing PII in a system prompt corrupts the
-- model's instructions (e.g. the example email in a "Co-Authored-By" git
-- commit template gets replaced with [MYRA-REDACT-…]).  Only user messages
-- should be scanned for PII.
--
-- Implementation: parse the request JSON, extract each non-user message's
-- content, and find its literal byte position in the raw body with a plain
-- string search.  This works correctly for ASCII PII (email, phone, SSN).
-- Non-ASCII content is skipped gracefully — the search will simply fail to
-- match and the range is not added, which is safe (we might over-tokenize a
-- system prompt with non-ASCII PII, but that is the existing behaviour).
--
-- Returns an array of {s=start_byte_0based, e=end_byte_0based} intervals.
-- ---------------------------------------------------------------------------
local SKIP_ROLES = { system = true, assistant = true }

local function build_exclusion_ranges(raw_body)
    local ok, parsed = pcall(json.decode, raw_body)
    if not ok or type(parsed) ~= "table" then return {} end

    local msgs = parsed.messages
    if type(msgs) ~= "table" then return {} end

    local ranges   = {}
    local search_from = 1  -- advance cursor so equal substrings in later roles
                           -- don't shadow earlier positions

    for _, msg in ipairs(msgs) do
        if SKIP_ROLES[msg.role] then
            local content = msg.content
            local texts   = {}

            if type(content) == "string" then
                texts[1] = content
            elseif type(content) == "table" then
                for _, part in ipairs(content) do
                    if type(part) == "table" and part.type == "text"
                       and type(part.text) == "string" then
                        texts[#texts + 1] = part.text
                    end
                end
            end

            for _, t in ipairs(texts) do
                if #t > 0 then
                    local s = raw_body:find(t, search_from, true)
                    if s then
                        ranges[#ranges + 1] = { s = s - 1, e = s - 1 + #t }
                        search_from = s + #t
                    end
                end
            end
        end
    end
    return ranges
end

-- Returns true when the entity span [e.start, e.end) is fully contained
-- within any of the exclusion ranges.
local function in_exclusion_ranges(entity, ranges)
    local es, ee = entity.start, entity["end"]
    for _, r in ipairs(ranges) do
        if es >= r.s and ee <= r.e then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- resolve_overlaps: greedy interval deduplication.
-- Sort by start ascending (higher score first on ties). Walk spans, accepting
-- each non-overlapping span. When a span overlaps the accepted region, replace
-- the last accepted span only if the new span has a strictly higher score.
-- Returns a new array sorted by start ascending.
-- ---------------------------------------------------------------------------
local function resolve_overlaps(entities)
    if #entities == 0 then return {} end

    local sorted = {}
    for _, e in ipairs(entities) do sorted[#sorted + 1] = e end
    table.sort(sorted, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.score > b.score
    end)

    local result  = {}
    local cur_end = -1

    for _, e in ipairs(sorted) do
        if e.start >= cur_end then
            result[#result + 1] = e
            cur_end = e["end"]
        elseif e.score > result[#result].score then
            result[#result] = e
            if e["end"] > cur_end then cur_end = e["end"] end
        end
        -- equal or lower score overlapping span: skip
    end

    return result
end

-- ---------------------------------------------------------------------------
-- derive_salt: 6-char hex prefix from MD5 of request_id + ngx.now().
-- ---------------------------------------------------------------------------
local function derive_salt(ctx)
    local seed = (ctx.request_id or "") .. tostring(ngx.now())
    return ngx.md5(seed):sub(1, 6)
end

-- ---------------------------------------------------------------------------
-- char_to_byte_pos: convert a 0-based Unicode codepoint offset to a
-- 1-based Lua byte position in a UTF-8 string.
--
-- Presidio (Python) returns codepoint offsets; Lua string.sub works on bytes.
-- For ASCII-only text they are equal, but for multi-byte UTF-8 sequences
-- (emoji, accented chars, CJK, etc.) the positions diverge.
-- Without this conversion, tokenize_spans cuts the JSON at the wrong byte,
-- potentially splitting a `"` boundary and producing invalid JSON.
-- ---------------------------------------------------------------------------
local function char_to_byte_pos(s, char_pos_0based)
    local byte_i = 1
    local char_i = 0
    while char_i < char_pos_0based and byte_i <= #s do
        local b = s:byte(byte_i)
        if     b < 0x80 then byte_i = byte_i + 1  -- 1-byte ASCII
        elseif b < 0xE0 then byte_i = byte_i + 2  -- 2-byte
        elseif b < 0xF0 then byte_i = byte_i + 3  -- 3-byte
        else                  byte_i = byte_i + 4  -- 4-byte (supplementary)
        end
        char_i = char_i + 1
    end
    return byte_i
end

-- ---------------------------------------------------------------------------
-- tokenize_spans: replace entity spans right-to-left with [MYRA-REDACT:salt:N] tokens.
-- Deduplicates: same original value → same token.
-- Presidio uses 0-based exclusive-end codepoint offsets; Lua string.sub uses
-- 1-based inclusive-end byte positions.  char_to_byte_pos() bridges the gap.
-- Returns: tokenized_text, token_map { token → original_value }
-- ---------------------------------------------------------------------------
local function tokenize_spans(text, spans, salt)
    local value_to_token = {}
    local token_map      = {}
    local counter        = 0

    -- Sort descending by start so right-to-left replacement keeps earlier offsets valid.
    local sorted = {}
    for _, s in ipairs(spans) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return a.start > b.start end)

    local result = text
    for _, sp in ipairs(sorted) do
        -- Convert Presidio's 0-based codepoint offsets to Lua 1-based byte positions.
        local lua_s = char_to_byte_pos(text, sp.start)          -- inclusive start
        local lua_e = char_to_byte_pos(text, sp["end"]) - 1     -- exclusive end → inclusive

        -- Skip malformed spans
        if lua_e >= lua_s and lua_s >= 1 and lua_e <= #text then
            local original = text:sub(lua_s, lua_e)  -- from original text (offsets still valid)

            local tok = value_to_token[original]
            if not tok then
                counter             = counter + 1
                tok                 = string.format("[MYRA-REDACT-%s:%s:%d]", sp.entity_type or sp.type or "PII", salt, counter)
                value_to_token[original] = tok
                token_map[tok]      = original
            end

            result = result:sub(1, lua_s - 1) .. tok .. result:sub(lua_e + 1)
        else
            ngx.log(ngx.WARN, "pii_protector: skipping out-of-range span start=",
                    sp.start, " end=", sp["end"], " byte_s=", lua_s, " byte_e=", lua_e,
                    " text_len=", #text)
        end
    end

    return result, token_map
end

-- ---------------------------------------------------------------------------
-- restore_tokens: plain-string token replacement in response body.
-- Uses string.find(..., plain=true) to avoid Lua magic-char issues with [ and ].
-- Returns: restored_text, count_of_distinct_tokens_replaced
-- ---------------------------------------------------------------------------
local function restore_tokens(text, token_map)
    local result = text
    local count  = 0

    for token, original in pairs(token_map) do
        local parts   = {}
        local pos     = 1
        local found   = false

        while true do
            local s, e = result:find(token, pos, true)  -- plain=true
            if not s then break end
            found           = true
            parts[#parts+1] = result:sub(pos, s - 1)
            parts[#parts+1] = original
            pos             = e + 1
        end

        if found then
            parts[#parts+1] = result:sub(pos)
            result          = table.concat(parts)
            count           = count + 1
        end
    end

    return result, count
end

-- ---------------------------------------------------------------------------
-- collect_entity_types: comma-separated entity type names for logging.
-- Does NOT include matched text to avoid PII in logs.
-- ---------------------------------------------------------------------------
-- extract_scrubbed_prompt: build a compact, human-readable log of only the
-- message(s) that contain PII tokens.  Skips clean messages and all request
-- metadata (model, max_tokens, tools, etc.).
--
-- Supports:
--   body.messages[]  — OpenAI-compat and native Anthropic
--   body.system      — Anthropic system prompt (string or content-block array)
--   body.prompt      — legacy completions-style
--
-- Returns a string, or nil if nothing relevant found / decode fails.
-- ---------------------------------------------------------------------------
local TOKEN_MARKER = "%[MYRA%-REDACT"   -- Lua pattern to detect tokens

local function block_array_to_text(blocks)
    if type(blocks) ~= "table" then return tostring(blocks) end
    local parts = {}
    for _, b in ipairs(blocks) do
        if b.type == "text" and b.text then parts[#parts+1] = b.text end
    end
    return table.concat(parts, "\n")
end

local function extract_scrubbed_prompt(tokenized_body)
    local ok, body = pcall(json.decode, tokenized_body)
    if not ok or not body then return nil end

    local lines = {}

    -- System prompt (Anthropic native)
    if body.system then
        local text = type(body.system) == "string"
                     and body.system
                     or block_array_to_text(body.system)
        if text:find(TOKEN_MARKER) then
            lines[#lines+1] = "[system] " .. text
        end
    end

    -- Messages array
    if type(body.messages) == "table" then
        for _, msg in ipairs(body.messages) do
            local text = type(msg.content) == "string"
                         and msg.content
                         or block_array_to_text(msg.content or {})
            if text:find(TOKEN_MARKER) then
                lines[#lines+1] = "[" .. (msg.role or "?") .. "] " .. text
            end
        end
    end

    -- Legacy completions prompt
    if body.prompt and type(body.prompt) == "string" then
        if body.prompt:find(TOKEN_MARKER) then
            lines[#lines+1] = "[prompt] " .. body.prompt
        end
    end

    if #lines == 0 then return nil end
    return table.concat(lines, "\n\n")
end

-- ---------------------------------------------------------------------------
local function collect_entity_types(entities)
    local seen  = {}
    local types = {}
    for _, e in ipairs(entities) do
        local et = e.entity_type or e.type
        if et and not seen[et] then
            seen[et]        = true
            types[#types+1] = et
        end
    end
    return table.concat(types, ",")
end

-- ---------------------------------------------------------------------------
-- M.run — public entry point called by the orchestrator.
-- Signature: M.run(ctx, detector, phase) → { verdict, [pattern] }
-- ---------------------------------------------------------------------------
function M.run(ctx, detector, phase)
    local fail_open = detector.fail_open
    if fail_open == nil then fail_open = true end

    -- -----------------------------------------------------------------------
    -- RESPONSE PHASE: restore tokens back to original values.
    -- -----------------------------------------------------------------------
    if phase == "response" then
        -- No token map means request phase found no PII; nothing to restore.
        if not ctx.pii_token_map then
            return { verdict = "pass" }
        end

        local text = ctx.response_body
        if not text or text == "" then
            return { verdict = "pass" }
        end

        local restored, count = restore_tokens(text, ctx.pii_token_map)

        -- Always capture the raw LLM response when PII was tokenized in the
        -- request phase, regardless of whether the LLM echoed tokens back.
        -- This lets operators verify what the LLM actually said.
        if detector.log_raw_response ~= false
           and ctx.gateway_config
           and ctx.gateway_config.log_payloads then
            ctx.log_fields.response_raw = text
        end

        if count > 0 then
            ctx.response_body = restored
            ngx.log(ngx.INFO, "pii_protector: restored ", count,
                    " PII token(s) in response name=", detector.name or "?")
            return { verdict = "scrubbed", pattern = "pii_token_restore" }
        end

        -- Tokens not found: LLM paraphrased rather than echoing tokens.
        -- Privacy is still preserved (LLM never saw real PII).
        return { verdict = "pass" }
    end

    -- -----------------------------------------------------------------------
    -- REQUEST PHASE: detect PII and replace with tokens.
    -- -----------------------------------------------------------------------
    local text = ctx.raw_request_body
    if not text or text == "" then
        return { verdict = "pass" }
    end

    -- Step 1: detect
    local entities, err = call_analyzer(text, detector)
    if not entities then
        ngx.log(ngx.WARN, "pii_protector: analyzer error: ", err,
                " name=", detector.name or "?")
        if fail_open then
            return { verdict = "pass" }
        end
        return { verdict = "block", pattern = "pii_protector_error" }
    end

    if #entities == 0 then
        return { verdict = "pass" }
    end

    -- Apply per-entity score floors (drops high-FP entities like PERSON/LOCATION
    -- unless they exceed the higher threshold or the user explicitly configures them).
    entities = apply_entity_thresholds(entities, detector)

    if #entities == 0 then
        return { verdict = "pass" }
    end

    -- Drop entities whose spans fall entirely within system/assistant message
    -- content.  System prompts are operator-controlled; assistant turns are
    -- model-generated.  Neither is user-supplied PII, and tokenizing them
    -- corrupts the model's own instructions.
    -- Opt-out: set skip_system_messages = false in the detector config.
    if detector.skip_system_messages ~= false then
        local excl = build_exclusion_ranges(text)
        if #excl > 0 then
            local filtered = {}
            for _, e in ipairs(entities) do
                if not in_exclusion_ranges(e, excl) then
                    filtered[#filtered + 1] = e
                end
            end
            entities = filtered
        end
    end

    if #entities == 0 then
        return { verdict = "pass" }
    end

    -- Step 2: resolve overlapping spans
    local clean_spans = resolve_overlaps(entities)

    -- Step 3: tokenize
    local salt             = derive_salt(ctx)
    local tokenized, tmap  = tokenize_spans(text, clean_spans, salt)

    -- Guard: all spans were malformed
    local map_size = 0
    for _ in pairs(tmap) do map_size = map_size + 1 end
    if map_size == 0 then
        return { verdict = "pass" }
    end

    -- Guard: tokenization must not produce invalid JSON escape sequences.
    -- Presidio returns codepoint offsets into the raw JSON body which includes
    -- \uXXXX escape sequences.  If a span boundary lands inside such an escape
    -- (e.g. at the 'u' of \u0040), tokenize_spans splits it, producing output
    -- like \[MYRA-REDACT-...] — an invalid JSON escape that Anthropic's strict
    -- parser rejects with "invalid escaped character in string".
    -- Fail open: skip tokenization if the result contains any invalid escape.
    do
        local pos = 1
        local bad = false
        while pos <= #tokenized do
            local bs = tokenized:find("\\", pos, true)
            if not bs then break end
            local nc = tokenized:sub(bs + 1, bs + 1)
            -- Valid JSON escape chars: " \ / b f n r t u
            if nc ~= '"'  and nc ~= '\\'  and nc ~= '/'
            and nc ~= 'b' and nc ~= 'f'   and nc ~= 'n'
            and nc ~= 'r' and nc ~= 't'   and nc ~= 'u'
            and nc ~= ''  then
                bad = true
                break
            end
            pos = bs + 2
        end
        if bad then
            ngx.log(ngx.WARN, "pii_protector: tokenization introduced invalid JSON escape",
                    " — skipping tokenization to preserve request integrity",
                    " name=", detector.name or "?")
            return { verdict = "pass" }
        end
    end

    -- Step 4: persist and update body.
    -- The orchestrator calls ngx.req.set_body_data(ctx.raw_request_body) for us
    -- after we return verdict="scrubbed".
    ctx.pii_token_map    = tmap
    ctx.raw_request_body = tokenized

    -- Log only the affected messages (those containing PII tokens) so operators
    -- can audit which values were masked without storing the full request JSON.
    if ctx.gateway_config and ctx.gateway_config.log_payloads then
        local scrubbed_excerpt = extract_scrubbed_prompt(tokenized)
        if scrubbed_excerpt then
            ctx.log_fields = ctx.log_fields or {}
            ctx.log_fields.prompt_scrubbed = scrubbed_excerpt
        end
    end

    -- For compat (OpenAI-format) clients that requested streaming: force the
    -- upstream call to be buffered so the response phase can restore tokens and
    -- capture response_raw.  send_response.lua re-emits the result as SSE.
    if ctx.is_compat and ctx.request_body and ctx.request_body.stream == true then
        ctx.pii_force_buffered = true
    end

    local entity_types = collect_entity_types(entities)
    ngx.log(ngx.INFO, "pii_protector: tokenized ", map_size,
            " unique PII value(s) types=", entity_types,
            " name=", detector.name or "?")

    return { verdict = "scrubbed", pattern = entity_types }
end

return M
