-- providers/openai.lua — OpenAI and Azure OpenAI adapter
--
-- Provider module interface (all providers must implement):
--   M.base_url(ctx)              → string
--   M.build_headers(ctx, key)    → table
--   M.build_request(ctx)         → body_string | nil, err
--   M.parse_response(body_str)   → { content, input_tokens, output_tokens } | nil, err
--   M.parse_sse_chunk(line)      → { delta, input_tokens, output_tokens, done } | nil

local json = require("utils.json")

local M = {}

-- Azure endpoint template when gateway_config.azure_endpoint is set:
--   https://{resource}.openai.azure.com/openai/deployments/{deployment}/...
local OPENAI_BASE = "https://api.openai.com"

function M.base_url(ctx)
    if ctx.gateway_config.azure_endpoint then
        local ep   = ctx.gateway_config.azure_endpoint  -- full base URL
        local ver  = ctx.gateway_config.azure_api_version or "2024-02-01"
        local path = ctx.provider_path  -- e.g. /chat/completions
        return ep .. path .. "?api-version=" .. ver
    end
    return OPENAI_BASE .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["X-Request-Id"]  = ctx.request_id or "",
    }
    if ctx.gateway_config.azure_endpoint then
        headers["Authorization"]  = nil
        headers["api-key"]        = api_key
    end
    -- Forward any x-aig-provider-* headers as provider-specific overrides.
    -- Blocked: credentials and headers already controlled by the gateway.
    local BLOCKED = {
        ["authorization"]  = true,
        ["api-key"]        = true,
        ["x-api-key"]      = true,
        ["content-type"]   = true,
        ["x-request-id"]   = true,
    }
    local req_headers = ngx.req.get_headers()
    for k, v in pairs(req_headers) do
        local fwd = k:match("^x%-aig%-provider%-(.+)$")
        if fwd and not BLOCKED[fwd:lower()] then headers[fwd] = v end
    end
    return headers
end

-- Pass the request body through unchanged (OpenAI is our canonical format).
-- Inject stream_options.include_usage=true for streaming so that the final
-- chunk carries prompt/completion token counts (needed by the UI stats bar).
function M.build_request(ctx)
    local body = ctx.request_body
    if body and body.stream then
        local patched = {}
        for k, v in pairs(body) do patched[k] = v end
        patched.stream_options = { include_usage = true }
        return json.sanitize_surrogates(json.encode(patched))
    end
    return json.sanitize_surrogates(json.encode(body))
end

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then
        return nil, "json decode failed"
    end
    if body.error then
        return nil, body.error.message or "provider error"
    end
    local choice  = body.choices and body.choices[1]
    local content = choice and (
        (choice.message and choice.message.content) or
        choice.text
    ) or ""
    local usage = body.usage or {}
    return {
        content       = content,
        input_tokens  = usage.prompt_tokens     or 0,
        output_tokens = usage.completion_tokens or 0,
        raw           = body,
    }
end

-- Parse a single SSE data line for streaming responses.
-- Returns a table or nil (for non-data or keep-alive lines).
function M.parse_sse_chunk(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end
    if data == "[DONE]" then
        return { done = true }
    end
    local chunk = json.decode(data)
    if not chunk then return nil end

    local delta  = ""
    local choice = chunk.choices and chunk.choices[1]
    if choice and choice.delta then
        -- Use only delta.content for the visible answer.
        -- delta.reasoning is the model's internal chain-of-thought and must
        -- never be forwarded to the client regardless of whether it contains
        -- <think> tags or plain prose.  The actual answer always arrives in
        -- delta.content once the reasoning phase is complete.
        delta = choice.delta.content or ""
    end

    -- OpenAI sends usage in the final chunk when stream_options.include_usage=true
    local usage = chunk.usage
    return {
        delta         = delta,
        done          = (choice and type(choice.finish_reason) == "string") or false,
        stop_reason   = choice and choice.finish_reason or nil,
        input_tokens  = usage and usage.prompt_tokens     or nil,
        output_tokens = usage and usage.completion_tokens or nil,
    }
end

return M
