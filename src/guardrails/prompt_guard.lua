-- guardrails/prompt_guard.lua — Tier 2 Llama Guard (Prompt Guard) sidecar guardrail
-- Implements Llama Guard 3 sidecar classification for request and response phases.
-- Supports request and response phases, category filtering, and flag action.

local json      = require("utils.json")
local http_util = require("utils.http")

local M = {}

local DEFAULT_URL     = "http://127.0.0.1:8083"
local DEFAULT_TIMEOUT = 2000

-- Extract text from a message content value (string or Anthropic content-block array).
local function content_to_text(content)
    if type(content) == "string" then return content end
    if type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
            if block.type == "text" and block.text then
                parts[#parts + 1] = block.text
            end
        end
        return table.concat(parts, "\n")
    end
    return ""
end

-- Llama Guard 3 max context is 4096 tokens; approximate at ~3 chars/token.
-- Note: when context_prompt is set it consumes ~200 chars, leaving ~8800 for user content.
local MAX_CHARS = 9000

local function truncate(text)
    if #text <= MAX_CHARS then return text end
    -- Keep the tail (most recent content is most relevant for safety)
    return "...[truncated]...\n" .. text:sub(-MAX_CHARS)
end

-- Extract the last user message for request-phase classification.
-- Only sends the last user turn to avoid alternating-role issues.
local function extract_request_messages(body, context_prompt)
    if not body then return nil end
    if body.messages and #body.messages > 0 then
        for i = #body.messages, 1, -1 do
            local msg = body.messages[i]
            if msg.role == "user" then
                local text = content_to_text(msg.content)
                if context_prompt then
                    text = "[Context: " .. context_prompt .. "]\n\n" .. text
                end
                if text ~= "" then
                    return {{ role = "user", content = truncate(text) }}
                end
            end
        end
        return nil
    end
    if body.prompt then
        local text = tostring(body.prompt)
        if context_prompt then
            text = "[Context: " .. context_prompt .. "]\n\n" .. text
        end
        return {{ role = "user", content = truncate(text) }}
    end
    return nil
end

-- Extract assistant text from a JSON response body for response-phase classification.
-- Falls back to raw text if parsing fails or no assistant content found.
local function extract_response_messages(response_body_text, context_prompt)
    if not response_body_text or response_body_text == "" then return nil end

    local ok, parsed = pcall(json.decode, response_body_text)
    if ok and parsed then
        -- OpenAI-compat: choices[1].message.content
        if parsed.choices and parsed.choices[1] then
            local choice = parsed.choices[1]
            local msg    = choice.message or choice.delta
            if msg then
                local text = content_to_text(msg.content)
                if context_prompt then
                    text = "[Context: " .. context_prompt .. "]\n\n" .. text
                end
                if text ~= "" then
                    return {{ role = "assistant", content = truncate(text) }}
                end
            end
        end
        -- Anthropic: content array of blocks
        if parsed.content then
            local text = content_to_text(parsed.content)
            if context_prompt then
                text = "[Context: " .. context_prompt .. "]\n\n" .. text
            end
            if text ~= "" then
                return {{ role = "assistant", content = truncate(text) }}
            end
        end
    end

    -- Fall back to raw text
    local text = response_body_text
    if context_prompt then
        text = "[Context: " .. context_prompt .. "]\n\n" .. text
    end
    return {{ role = "assistant", content = truncate(text) }}
end

-- Call Llama Guard 3.
-- Returns { verdict="safe"|"unsafe", categories="S2,S9"|nil } or nil, err.
local function classify(messages, detector)
    local url     = (detector.url or DEFAULT_URL) .. "/v1/chat/completions"
    local read_ms = detector.timeout_ms or DEFAULT_TIMEOUT

    local payload = json.encode({
        model       = "llama-guard-3-8b",
        messages    = messages,
        max_tokens  = 20,
        temperature = 0,
    })

    local status, _, body, err = http_util.request({
        method             = "POST",
        url                = url,
        headers            = { ["Content-Type"] = "application/json" },
        body               = payload,
        connect_timeout_ms = 500,
        send_timeout_ms    = 2000,
        read_timeout_ms    = read_ms,
    })

    if err or not body then
        return nil, "request: " .. tostring(err)
    end
    if status ~= 200 then
        return nil, "http " .. tostring(status)
    end

    local resp = json.decode(body)
    if not resp or not resp.choices or not resp.choices[1] then
        return nil, "parse_response"
    end

    local content = resp.choices[1].message and resp.choices[1].message.content or ""
    content       = content:match("^%s*(.-)%s*$")  -- trim whitespace
    local verdict    = content:match("^(%a+)")
    local categories = content:match("\n(.+)$")
    return { verdict = verdict, categories = categories }
end

-- Filter category codes through detector.categories whitelist.
-- Returns the intersection as a comma-separated string, or nil if empty.
local function filter_categories(raw_cats, allowed_set)
    if not allowed_set or #allowed_set == 0 then
        -- No filter: return as-is
        return raw_cats
    end

    -- Build lookup
    local allowed = {}
    for _, c in ipairs(allowed_set) do allowed[c] = true end

    local matched = {}
    if raw_cats then
        for code in raw_cats:gmatch("[^,]+") do
            local trimmed = code:match("^%s*(.-)%s*$")
            if allowed[trimmed] then
                matched[#matched + 1] = trimmed
            end
        end
    end

    if #matched == 0 then return nil end
    return table.concat(matched, ",")
end

function M.run(ctx, detector, phase)
    local fail_open = detector.fail_open
    if fail_open == nil then fail_open = true end

    local action         = detector.action or "block"
    local context_prompt = detector.context_prompt or nil

    -- Build the messages list based on phase
    local messages
    if phase == "response" then
        messages = extract_response_messages(ctx.response_body, context_prompt)
    else
        -- request phase: parse body if needed
        if not ctx.request_body then
            local req_util = require("utils.request")
            if not ctx.raw_request_body then
                ctx.raw_request_body = req_util.read_body() or ""
            end
            ctx.request_body = json.decode(ctx.raw_request_body) or {}
        end
        messages = extract_request_messages(ctx.request_body, context_prompt)
    end

    if not messages then
        return { verdict = "pass" }
    end

    local t0 = ngx.now()
    local result, classify_err = classify(messages, detector)
    local latency_ms = math.floor((ngx.now() - t0) * 1000)

    -- Record latency and verdict in log_fields (mirroring guardrails_request.lua)
    ctx.log_fields = ctx.log_fields or {}
    ctx.log_fields.guardrail_latency_ms = latency_ms

    if not result then
        ngx.log(ngx.WARN, "prompt_guard:sidecar unavailable: ", classify_err,
                " detector=", detector.name or "?",
                " tenant=", ctx.tenant_id)
        ctx.log_fields.guardrail_verdict = "error"
        if fail_open then
            return { verdict = "pass" }
        else
            return { verdict = "block", pattern = classify_err }
        end
    end

    if result.verdict ~= "unsafe" then
        ctx.log_fields.guardrail_verdict = "safe"
        return { verdict = "pass" }
    end

    -- Apply category filter if detector.categories is configured
    local effective_cats = filter_categories(result.categories, detector.categories)

    if effective_cats == nil then
        -- The detected categories do not intersect the allowed filter → treat as safe
        ctx.log_fields.guardrail_verdict = "safe"
        return { verdict = "pass" }
    end

    ctx.log_fields.guardrail_verdict = "unsafe"
    ngx.log(ngx.WARN, "prompt_guard:unsafe content detected detector=", detector.name or "?",
            " tenant=", ctx.tenant_id, " categories=", effective_cats)

    if action == "block" then
        return { verdict = "block", pattern = effective_cats }
    else
        return { verdict = "flagged", pattern = effective_cats }
    end
end

return M
