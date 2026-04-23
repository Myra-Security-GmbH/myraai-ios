-- guardrails/custom_pii.lua — Tier-1 custom keyword PII tokenizer (AGF-2).
--
-- Works like pii_protector but for admin-defined sensitive terms (client names,
-- project codenames, employee surnames, etc.) that Presidio's generic NER misses.
--
-- Request phase:
--   Scans decoded user message text for each keyword in detector.keywords.
--   Replaces every match with an opaque token [MYRA-CUSTOM:salt:N].
--   Stores the reverse map in ctx.pii_token_map (shared with pii_protector so
--   either module can restore in the response phase).
--
-- Response phase:
--   Restores tokens → original values using plain-string replacement.
--
-- Token format: [MYRA-CUSTOM:SALT:N]
--   SALT = first 6 hex chars of MD5(request_id .. ngx.now()) — per-request unique
--   N    = sequential counter (shared with pii_protector if both are configured)
--
-- Options:
--   keywords        — array of strings (required)
--   case_sensitive  — default false (ASCII case folding; for non-ASCII enter exact case)
--   whole_word      — default false (substring match by default)

local json = require("utils.json")

local M = {}

-- ---------------------------------------------------------------------------
-- collect_texts: extract decoded user message strings from ctx.request_body.
-- Returns array of {mi, bi, text, is_prompt} — same shape as pii_protector's
-- fields so set_text() can write back modified text in-place.
-- ---------------------------------------------------------------------------
local function collect_texts(body)
    local fields = {}
    if type(body.messages) == "table" then
        for mi, msg in ipairs(body.messages) do
            if msg.role == "user" then
                local content = msg.content
                if type(content) == "string" then
                    fields[#fields + 1] = { mi = mi, bi = nil, text = content }
                elseif type(content) == "table" then
                    for bi, block in ipairs(content) do
                        if type(block) == "table" and block.type == "text"
                           and type(block.text) == "string" then
                            fields[#fields + 1] = { mi = mi, bi = bi, text = block.text }
                        end
                    end
                end
            end
        end
    end
    if type(body.prompt) == "string" then
        fields[#fields + 1] = { mi = nil, bi = nil, text = body.prompt, is_prompt = true }
    end
    return fields
end

local function set_text(body, field)
    if field.is_prompt then
        body.prompt = field.text
    elseif field.bi then
        body.messages[field.mi].content[field.bi].text = field.text
    else
        body.messages[field.mi].content = field.text
    end
end

-- ---------------------------------------------------------------------------
-- replace_all: replace every occurrence of keyword in text with token.
-- When case_sensitive=false, detection uses lowercased copies but replacement
-- preserves the original surrounding text.
-- Returns: new_text, count_of_replacements
-- ---------------------------------------------------------------------------
local function replace_all(text, keyword, token, case_sensitive, whole_word)
    local haystack = case_sensitive and text or text:lower()
    local needle   = case_sensitive and keyword or keyword:lower()
    local kw_len   = #needle
    if kw_len == 0 then return text, 0 end

    local parts = {}
    local pos   = 1
    local count = 0

    while true do
        local s = haystack:find(needle, pos, true)  -- plain=true, no magic chars
        if not s then break end
        local e = s + kw_len - 1

        -- Whole-word check: character before start and after end must be non-word.
        if whole_word then
            local before = s > 1 and haystack:sub(s - 1, s - 1) or " "
            local after  = e < #haystack and haystack:sub(e + 1, e + 1) or " "
            local before_ok = not before:match("%w")
            local after_ok  = not after:match("%w")
            if not (before_ok and after_ok) then
                pos = s + 1
                goto continue
            end
        end

        parts[#parts + 1] = text:sub(pos, s - 1)
        parts[#parts + 1] = token
        pos   = e + 1
        count = count + 1

        ::continue::
        if pos > #text then break end
    end

    if count == 0 then return text, 0 end
    parts[#parts + 1] = text:sub(pos)
    return table.concat(parts), count
end

-- ---------------------------------------------------------------------------
-- restore_tokens: plain-string token → original value replacement.
-- Mirrors pii_protector's restore_tokens so both modules can use the shared map.
-- ---------------------------------------------------------------------------
local function restore_tokens(text, token_map)
    local result = text
    local count  = 0
    for token, original in pairs(token_map) do
        -- Only process tokens we emitted (MYRA-CUSTOM prefix)
        if token:find("[MYRA-CUSTOM:", 1, true) then
            local parts = {}
            local pos   = 1
            local found = false
            while true do
                local s, e = result:find(token, pos, true)
                if not s then break end
                found           = true
                parts[#parts+1] = result:sub(pos, s - 1)
                parts[#parts+1] = original
                pos             = e + 1
            end
            if found then
                parts[#parts+1] = result:sub(pos)
                result = table.concat(parts)
                count  = count + 1
            end
        end
    end
    return result, count
end

-- ---------------------------------------------------------------------------
-- M.run — public entry point called by the orchestrator.
-- ---------------------------------------------------------------------------
function M.run(ctx, detector, phase)
    local keywords      = detector.keywords or {}
    local case_sensitive = detector.case_sensitive == true   -- default false
    local whole_word    = detector.whole_word == true        -- default false

    -- -----------------------------------------------------------------------
    -- RESPONSE PHASE: restore custom PII tokens.
    -- -----------------------------------------------------------------------
    if phase == "response" then
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
            ngx.log(ngx.INFO, "custom_pii: restored ", count,
                    " custom keyword token(s) name=", detector.name or "?")
            return { verdict = "scrubbed", pattern = "custom_pii_restore" }
        end
        return { verdict = "pass" }
    end

    -- -----------------------------------------------------------------------
    -- REQUEST PHASE: find and tokenize custom keywords.
    -- -----------------------------------------------------------------------
    if #keywords == 0 then
        return { verdict = "pass" }
    end

    -- Ensure request body is parsed
    if not ctx.request_body then
        local req_util = require("utils.request")
        if not ctx.raw_request_body then
            ctx.raw_request_body = req_util.read_body() or ""
        end
        ctx.request_body = json.decode(ctx.raw_request_body) or {}
    end
    local body = ctx.request_body

    local fields = collect_texts(body)
    if #fields == 0 then
        return { verdict = "pass" }
    end

    -- Derive a per-request salt (shared with pii_protector if both are active)
    local seed = (ctx.request_id or "") .. tostring(ngx.now())
    local salt = ngx.md5(seed):sub(1, 6)

    -- Initialise or reuse the shared token map and counter.
    ctx.pii_token_map = ctx.pii_token_map or {}
    ctx.custom_pii_counter = ctx.custom_pii_counter or 0

    -- value_to_token: deduplication — same original value → same token
    local value_to_token = {}
    -- Invert existing map so we can dedup across pii_protector + custom_pii runs
    for tok, orig in pairs(ctx.pii_token_map) do
        value_to_token[orig] = tok
    end

    local any_tokenized  = false
    local matched_kws    = {}

    for _, field in ipairs(fields) do
        local text = field.text
        for _, kw in ipairs(keywords) do
            -- Check whether this keyword appears in the text at all
            local haystack = case_sensitive and text or text:lower()
            local needle   = case_sensitive and kw or kw:lower()
            if haystack:find(needle, 1, true) then
                -- Assign a token (deduplicated by original value)
                local tok = value_to_token[kw]
                if not tok then
                    ctx.custom_pii_counter = ctx.custom_pii_counter + 1
                    tok = string.format("[MYRA-CUSTOM:%s:%d]", salt, ctx.custom_pii_counter)
                    value_to_token[kw]    = tok
                    ctx.pii_token_map[tok] = kw
                end

                local new_text, n = replace_all(text, kw, tok, case_sensitive, whole_word)
                if n > 0 then
                    text           = new_text
                    any_tokenized  = true
                    matched_kws[kw] = true
                end
            end
        end
        if field.text ~= text then
            field.text = text
            set_text(body, field)
        end
    end

    if not any_tokenized then
        return { verdict = "pass" }
    end

    -- Re-encode and update raw request body
    local new_raw = json.encode(body)
    if not new_raw then
        ngx.log(ngx.WARN, "custom_pii: json.encode failed — skipping name=", detector.name or "?")
        return { verdict = "pass" }
    end
    ctx.raw_request_body = new_raw

    -- Force buffered mode for streaming compat requests (same as pii_protector)
    if ctx.is_compat and body.stream == true then
        ctx.pii_force_buffered        = true
        ctx.buffered_needs_sse_reemit = true
    end

    local kw_list = {}
    for kw in pairs(matched_kws) do kw_list[#kw_list + 1] = kw end
    local summary = table.concat(kw_list, ",")
    ngx.log(ngx.INFO, "custom_pii: masked keywords=[", summary, "]",
            " name=", detector.name or "?")

    -- Expose keyword count for the SSE pii_masked event (upstream.lua).
    -- Count only the distinct keywords matched in this run.
    local kw_count = #kw_list
    ctx.custom_pii_masked_count = (ctx.custom_pii_masked_count or 0) + kw_count

    return { verdict = "scrubbed", pattern = summary }
end

return M
