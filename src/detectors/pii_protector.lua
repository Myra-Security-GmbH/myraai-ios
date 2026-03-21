-- detectors/pii_protector.lua — Tier-2 reversible PII tokenizer.
--
-- Request phase:
--   Calls Presidio /analyze to locate PII spans, replaces each unique value
--   with a token [PII:SALT:N], and stores the reverse map in ctx.pii_token_map.
--   The upstream AI provider receives the tokenized body.
--
-- Response phase:
--   Finds tokens in ctx.response_body and replaces them with original values
--   before the response is sent to the client.
--
-- Token format: [PII:SALT:N]
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
-- The response-phase detector is skipped for streaming by detectors_response.lua.
-- Tokens remain visible in streamed output. The LLM never saw real PII so security
-- is preserved, but UX is degraded.

local json      = require("utils.json")
local http_util = require("utils.http")

local M = {}

local DEFAULT_ANALYZER_URL    = "http://127.0.0.1:5002"
local DEFAULT_SCORE_THRESHOLD = 0.7
local DEFAULT_LANGUAGE        = "en"

-- ---------------------------------------------------------------------------
-- call_analyzer: POST to Presidio /analyze.
-- Returns array of {entity_type, start, end, score} (0-based char offsets), or nil, err.
-- Mirrors the call pattern in detectors/presidio.lua.
-- ---------------------------------------------------------------------------
local function call_analyzer(text, detector)
    local url     = (detector.analyzer_url or DEFAULT_ANALYZER_URL) .. "/analyze"
    local timeout = detector.timeout_ms or 3000

    local payload = json.encode({
        text            = text,
        language        = detector.language or DEFAULT_LANGUAGE,
        entities        = detector.entities,
        score_threshold = detector.score_threshold or DEFAULT_SCORE_THRESHOLD,
    })

    local status, _, body, err = http_util.request({
        method  = "POST",
        url     = url,
        headers = { ["Content-Type"] = "application/json" },
        body    = payload,
        timeout_ms = timeout,
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
-- tokenize_spans: replace entity spans right-to-left with [PII:salt:N] tokens.
-- Deduplicates: same original value → same token.
-- Presidio uses 0-based exclusive-end offsets; Lua string.sub uses 1-based inclusive-end.
-- Conversion: lua_start = presidio_start + 1, lua_end = presidio_end (unchanged).
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
        local lua_s = sp.start + 1   -- 0-based → 1-based
        local lua_e = sp["end"]      -- exclusive in Presidio = inclusive in Lua sub

        -- Skip malformed spans
        if lua_e >= lua_s and lua_s >= 1 and lua_e <= #result then
            local original = text:sub(lua_s, lua_e)  -- from original text (offsets still valid)

            local tok = value_to_token[original]
            if not tok then
                counter             = counter + 1
                tok                 = string.format("[PII:%s:%d]", salt, counter)
                value_to_token[original] = tok
                token_map[tok]      = original
            end

            result = result:sub(1, lua_s - 1) .. tok .. result:sub(lua_e + 1)
        else
            ngx.log(ngx.WARN, "pii_protector: skipping malformed span start=",
                    sp.start, " end=", sp["end"], " text_len=", #text)
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

    -- Step 4: persist and update body.
    -- The orchestrator calls ngx.req.set_body_data(ctx.raw_request_body) for us
    -- after we return verdict="scrubbed".
    ctx.pii_token_map    = tmap
    ctx.raw_request_body = tokenized

    local entity_types = collect_entity_types(entities)
    ngx.log(ngx.INFO, "pii_protector: tokenized ", map_size,
            " unique PII value(s) types=", entity_types,
            " name=", detector.name or "?")

    return { verdict = "scrubbed", pattern = entity_types }
end

return M
