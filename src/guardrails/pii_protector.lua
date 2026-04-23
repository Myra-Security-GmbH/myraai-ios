-- guardrails/pii_protector.lua — Tier-2 reversible PII tokenizer.
--
-- Request phase:
--   Extracts decoded text from ctx.request_body (user messages only by default).
--   Calls Presidio /analyze on the decoded text.  Tokenizes PII spans in the
--   decoded strings, then re-encodes with json.encode — eliminating the class
--   of bugs caused by doing byte surgery on raw JSON while Presidio returns
--   Unicode codepoint offsets.
--   Stores the reverse map in ctx.pii_token_map.
--   The upstream AI provider receives the tokenized body via ctx.raw_request_body.
--
-- Response phase:
--   Finds tokens in ctx.response_body and replaces them with original values
--   before the response is sent to the client.
--
-- Token format: [MYRA-REDACT-TYPE:SALT:N]
--   SALT = first 6 hex chars of ngx.md5(request_id .. ngx.now()) — per-request unique
--   N    = sequential counter starting at 1
--   Characters [, ], :, alphanumerics are valid inside JSON strings without escaping.
--
-- Same original value → same token within a request (deduplication).
-- Overlapping spans → highest-score span wins (greedy resolution).
-- Right-to-left replacement preserves codepoint offsets for earlier spans.
-- Plain-string restore avoids Lua magic-char issues with [ and ] in gsub patterns.
--
-- Known limitation: streaming responses are not buffered (ctx.response_body is nil).
-- The response-phase guardrail is skipped for streaming by guardrails_response.lua.
-- Tokens remain visible in streamed output. The LLM never saw real PII so security
-- is preserved, but UX is degraded.

local json      = require("utils.json")
local http_util = require("utils.http")

local M = {}

local DEFAULT_ANALYZER_URL    = os.getenv("PRESIDIO_ANALYZER_URL") or "http://127.0.0.1:5002"
local DEFAULT_SCORE_THRESHOLD = 0.7
local DEFAULT_LANGUAGE        = "auto"

-- Entity types known to produce elevated false positive rates on legitimate text.
-- Applied as defaults when entity_score_thresholds is not explicitly configured.
-- See benchmarks in tests/false_positives/ for measured FP rates.
-- NRP (nationality/religion/politics) was a spaCy entity; no longer produced by GLiNER.
local HIGH_FP_ENTITY_THRESHOLDS = {
    PERSON    = 0.9,
    LOCATION  = 0.9,
    DATE_TIME = 0.9,
    ORG       = 0.85,
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
-- count_codepoints: count UTF-8 codepoints in str[1..n_bytes].
-- Used to track field boundaries in the NUL-joined Presidio input.
-- ---------------------------------------------------------------------------
local function count_codepoints(str, n_bytes)
    local count = 0
    local i     = 1
    while i <= n_bytes do
        local b = str:byte(i)
        if     b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else                  i = i + 4
        end
        count = count + 1
    end
    return count
end

-- ---------------------------------------------------------------------------
-- char_to_byte_pos: convert a 0-based Unicode codepoint offset to a
-- 1-based Lua byte position in a UTF-8 string.
--
-- Presidio (Python) returns codepoint offsets; Lua string.sub works on bytes.
-- For ASCII-only text they are equal, but for multi-byte UTF-8 sequences
-- (emoji, accented chars, CJK, etc.) the positions diverge.
-- ---------------------------------------------------------------------------
local function char_to_byte_pos(s, char_pos_0based)
    local byte_i = 1
    local char_i = 0
    while char_i < char_pos_0based and byte_i <= #s do
        local b = s:byte(byte_i)
        if     b < 0x80 then byte_i = byte_i + 1
        elseif b < 0xE0 then byte_i = byte_i + 2
        elseif b < 0xF0 then byte_i = byte_i + 3
        else                  byte_i = byte_i + 4
        end
        char_i = char_i + 1
    end
    return byte_i
end

-- ---------------------------------------------------------------------------
-- collect_user_texts: extract decoded text strings from ctx.request_body.
--
-- Returns:
--   joined  — all texts concatenated with NUL ("\0") separator.
--             NUL never appears in valid decoded JSON; 1 byte = 1 codepoint
--             so cursor arithmetic across the separator is trivial.
--   fields  — array of { mi, bi, text, cp_start } where
--               mi       = body.messages index (1-based)
--               bi       = content block index (1-based) or nil for plain strings
--               text     = decoded content string
--               cp_start = 0-based codepoint offset of this field in `joined`
--               is_prompt= true for the legacy body.prompt field
--
-- include_all=false (default): only role=="user" messages.
-- include_all=true            : all roles (used when skip_system_messages=false).
-- ---------------------------------------------------------------------------
local function collect_user_texts(body, include_all)
    if type(body) ~= "table" then return "", {} end

    local texts  = {}
    local fields = {}
    local cp_off = 0

    if type(body.messages) == "table" then
        for mi, msg in ipairs(body.messages) do
            if include_all or msg.role == "user" then
                local content = msg.content
                if type(content) == "string" then
                    local cp_len = count_codepoints(content, #content)
                    fields[#fields + 1] = { mi = mi, bi = nil, text = content, cp_start = cp_off }
                    texts[#texts + 1]   = content
                    cp_off = cp_off + cp_len + 1   -- +1 for NUL separator
                elseif type(content) == "table" then
                    for bi, block in ipairs(content) do
                        if type(block) == "table" and block.type == "text"
                           and type(block.text) == "string" then
                            local t      = block.text
                            local cp_len = count_codepoints(t, #t)
                            fields[#fields + 1] = { mi = mi, bi = bi, text = t, cp_start = cp_off }
                            texts[#texts + 1]   = t
                            cp_off = cp_off + cp_len + 1
                        end
                    end
                end
            end
        end
    end

    -- Legacy completions-style prompt
    if type(body.prompt) == "string" then
        local t      = body.prompt
        local cp_len = count_codepoints(t, #t)
        fields[#fields + 1] = { mi = nil, bi = nil, text = t, cp_start = cp_off, is_prompt = true }
        texts[#texts + 1]   = t
        cp_off = cp_off + cp_len + 1
    end

    return table.concat(texts, "\0"), fields
end

-- ---------------------------------------------------------------------------
-- set_body_field: write tokenized text back into the body table in-place.
-- ---------------------------------------------------------------------------
local function set_body_field(body, field)
    if field.is_prompt then
        body.prompt = field.text
    elseif field.bi then
        body.messages[field.mi].content[field.bi].text = field.text
    else
        body.messages[field.mi].content = field.text
    end
end

-- ---------------------------------------------------------------------------
-- tokenize_spans: replace entity spans right-to-left in a decoded text string.
-- Deduplicates: same original value → same token (shared maps across calls).
-- Presidio uses 0-based exclusive-end codepoint offsets; char_to_byte_pos()
-- converts to 1-based inclusive Lua byte positions.
-- Returns: tokenized_text
-- ---------------------------------------------------------------------------
local function tokenize_spans(text, spans, salt, value_to_token, token_map, counter)
    -- Sort descending by start so right-to-left replacement keeps earlier offsets valid.
    local sorted = {}
    for _, s in ipairs(spans) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return a.start > b.start end)

    local result = text
    for _, sp in ipairs(sorted) do
        -- Convert 0-based codepoint offsets to Lua 1-based byte positions.
        -- Use the original `text` for position arithmetic (left portion is
        -- identical in `result` since we process right-to-left).
        local lua_s = char_to_byte_pos(text, sp.start)
        local lua_e = char_to_byte_pos(text, sp["end"]) - 1

        if lua_e >= lua_s and lua_s >= 1 and lua_e <= #text then
            local original = text:sub(lua_s, lua_e)

            local tok = value_to_token[original]
            if not tok then
                counter.n               = counter.n + 1
                tok                     = string.format("[MYRA-REDACT-%s:%s:%d]",
                                            sp.entity_type or sp.type or "PII",
                                            salt, counter.n)
                value_to_token[original] = tok
                token_map[tok]          = original
            end

            result = result:sub(1, lua_s - 1) .. tok .. result:sub(lua_e + 1)
        else
            ngx.log(ngx.WARN, "pii_protector: skipping out-of-range span start=",
                    sp.start, " end=", sp["end"], " byte_s=", lua_s, " byte_e=", lua_e,
                    " text_len=", #text)
        end
    end

    return result
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
-- extract_scrubbed_prompt: build a compact log of only the message(s) that
-- contain PII tokens.  Takes the (already-tokenized) body table.
--
-- Supports:
--   body.messages[]  — OpenAI-compat and native Anthropic
--   body.system      — Anthropic system prompt (string or content-block array)
--   body.prompt      — legacy completions-style
--
-- Returns a string, or nil if nothing relevant found.
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

local function extract_scrubbed_prompt(body)
    if type(body) ~= "table" then return nil end

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
    --
    -- Architecture: extract decoded text → tokenize in decoded strings →
    -- re-encode with json.encode.  This eliminates the entire class of bugs
    -- caused by mapping Presidio's Unicode codepoint offsets onto raw JSON
    -- bytes (where \uXXXX escapes, \" sequences, etc. shift all positions).
    -- -----------------------------------------------------------------------
    if not ctx.request_body then
        -- Body may not have been parsed yet (happens when cache_ttl=0 so
        -- cache_check skipped parsing). Parse it now — skipping silently on a
        -- missing body turns this guardrail into a no-op.
        local req_util = require("utils.request")
        if not ctx.raw_request_body then
            ctx.raw_request_body = req_util.read_body() or ""
        end
        ctx.request_body = json.decode(ctx.raw_request_body) or {}
    end
    local body = ctx.request_body

    -- Collect decoded user text.
    -- skip_system_messages=false → include all roles (system + assistant + user).
    local include_all = (detector.skip_system_messages == false)
    local joined, fields = collect_user_texts(body, include_all)
    if joined == "" then
        return { verdict = "pass" }
    end

    -- Call Presidio with the decoded text (codepoint offsets in decoded strings
    -- are straightforward — no JSON escapes to miscount).
    local entities, err = call_analyzer(joined, detector)
    if not entities then
        return { verdict = "error", stage = "analyzer", message = err,
                 url = detector.analyzer_url or DEFAULT_ANALYZER_URL }
    end

    if #entities == 0 then
        return { verdict = "pass" }
    end

    -- Apply per-entity score floors.
    entities = apply_entity_thresholds(entities, detector)
    if #entities == 0 then
        return { verdict = "pass" }
    end

    -- Resolve overlapping spans across the entire joined text.
    local clean_spans = resolve_overlaps(entities)

    -- Tokenize each field independently.
    -- Spans are dispatched by checking whether they fall fully within the
    -- field's codepoint range [cp_start, cp_start + cp_len).
    -- Spans crossing field boundaries (i.e. crossing a NUL separator) are
    -- silently dropped — NUL never appears in user content so this only
    -- happens if Presidio mis-detects across the artificial boundary.
    local salt           = derive_salt(ctx)
    local value_to_token = {}   -- original_value → token (shared for dedup)
    local token_map      = {}   -- token → original_value (for response restore)
    local counter        = { n = 0 }
    local any_tokenized  = false

    for _, field in ipairs(fields) do
        local f_cp_start = field.cp_start
        local f_cp_len   = count_codepoints(field.text, #field.text)
        local f_cp_end   = f_cp_start + f_cp_len   -- exclusive upper bound

        -- Collect spans that lie fully within this field and remap to
        -- field-local 0-based codepoint offsets.
        local field_spans = {}
        for _, sp in ipairs(clean_spans) do
            if sp.start >= f_cp_start and sp["end"] <= f_cp_end then
                field_spans[#field_spans + 1] = {
                    entity_type = sp.entity_type or sp.type,
                    start       = sp.start   - f_cp_start,
                    ["end"]     = sp["end"]  - f_cp_start,
                    score       = sp.score,
                }
            end
            -- Cross-boundary spans silently dropped.
        end

        if #field_spans > 0 then
            local tokenized = tokenize_spans(
                field.text, field_spans, salt, value_to_token, token_map, counter)
            field.text = tokenized
            set_body_field(body, field)
            any_tokenized = true
        end
    end

    if not any_tokenized then
        return { verdict = "pass" }
    end

    -- Re-encode the updated body as JSON.
    -- If encoding fails (should not happen with a well-formed body table),
    -- fail open: leave ctx.raw_request_body unchanged.
    local new_raw = json.encode(body)
    if not new_raw then
        ngx.log(ngx.WARN, "pii_protector: json.encode failed after tokenization",
                " — skipping to preserve request integrity",
                " name=", detector.name or "?")
        return { verdict = "pass" }
    end

    ctx.pii_token_map    = token_map
    ctx.raw_request_body = new_raw

    -- Log only the affected messages so operators can audit which values were
    -- masked without storing the full request JSON.
    if ctx.gateway_config and ctx.gateway_config.log_payloads then
        local scrubbed_excerpt = extract_scrubbed_prompt(body)
        if scrubbed_excerpt then
            ctx.log_fields = ctx.log_fields or {}
            ctx.log_fields.prompt_scrubbed = scrubbed_excerpt
        end
    end

    -- For compat (OpenAI-format) clients that requested streaming: force the
    -- upstream call to be buffered so the response phase can restore tokens and
    -- capture response_raw.  send_response.lua re-emits the result as SSE.
    if ctx.is_compat and body.stream == true then
        ctx.pii_force_buffered      = true
        ctx.buffered_needs_sse_reemit = true
    end

    local entity_types = collect_entity_types(entities)
    ngx.log(ngx.INFO, "pii_protector: tokenized ", counter.n,
            " unique PII value(s) types=", entity_types,
            " name=", detector.name or "?")

    -- Expose entity types for the SSE pii_masked event (upstream.lua).
    -- Uses a comma-separated list of Presidio entity type names, e.g. "PERSON,EMAIL_ADDRESS".
    -- Append to any types already set by a previous pii_protector detector in the same request.
    if entity_types ~= "" then
        if ctx.pii_detected_types and ctx.pii_detected_types ~= "" then
            ctx.pii_detected_types = ctx.pii_detected_types .. "," .. entity_types
        else
            ctx.pii_detected_types = entity_types
        end
    end

    return { verdict = "scrubbed", pattern = entity_types }
end

return M
