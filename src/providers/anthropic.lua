-- providers/anthropic.lua — Anthropic Messages API adapter

local json = require("utils.json")

local M = {}

local BASE_URL = "https://api.anthropic.com"
local API_VERSION = "2023-06-01"

function M.base_url(ctx)
    -- Anthropic path is always /v1/messages (ignore ctx.provider_path)
    return BASE_URL .. "/v1/messages"
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = api_key,
        ["anthropic-version"] = API_VERSION,
        ["X-Request-Id"]      = ctx.request_id or "",
    }
    local req_headers = ngx.req.get_headers()
    -- Forward anthropic-beta (used by Claude Code for extended thinking etc.)
    if req_headers["anthropic-beta"] then
        headers["anthropic-beta"] = req_headers["anthropic-beta"]
    end
    -- Forward any x-aig-provider-* overrides as raw provider headers
    for k, v in pairs(req_headers) do
        local fwd = k:match("^x%-aig%-provider%-(.+)$")
        if fwd then headers[fwd] = v end
    end
    return headers
end

-- Convert OpenAI-style request to Anthropic Messages format.
-- ctx.request_body is always in OpenAI format (normalised by transform.lua).
function M.build_request(ctx)
    local src = ctx.request_body

    -- Separate system message from the messages array
    local system_msg
    local messages = {}
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            system_msg = msg.content
        else
            messages[#messages + 1] = {
                role    = msg.role,
                content = msg.content,
            }
        end
    end

    local body = {
        model      = ctx.model,
        max_tokens = src.max_tokens or 4096,
        messages   = messages,
    }
    if system_msg then body.system = system_msg end
    if src.temperature  then body.temperature   = src.temperature  end
    if src.top_p        then body.top_p         = src.top_p        end
    if src.stop         then body.stop_sequences = type(src.stop) == "table"
                                                   and src.stop
                                                   or {src.stop}  end
    if src.stream       then body.stream        = true             end

    return json.encode(body)
end

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then return nil, "json decode failed" end
    if body.type == "error" then
        return nil, (body.error and body.error.message) or "provider error"
    end

    local content = ""
    for _, block in ipairs(body.content or {}) do
        if block.type == "text" then
            content = content .. (block.text or "")
        end
    end

    local usage = body.usage or {}
    return {
        content       = content,
        input_tokens  = usage.input_tokens  or 0,
        output_tokens = usage.output_tokens or 0,
        raw           = body,
    }
end

-- Anthropic SSE events: content_block_delta, message_delta (with usage)
function M.parse_sse_chunk(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end

    local chunk = json.decode(data)
    if not chunk then return nil end

    local delta = ""
    if chunk.type == "content_block_delta" and chunk.delta then
        delta = chunk.delta.text or ""
    end

    local done = (chunk.type == "message_stop")

    local input_tokens, output_tokens
    if chunk.type == "message_delta" and chunk.usage then
        output_tokens = chunk.usage.output_tokens
    end
    if chunk.type == "message_start" and chunk.message and chunk.message.usage then
        input_tokens = chunk.message.usage.input_tokens
    end

    return {
        delta         = delta,
        done          = done,
        input_tokens  = input_tokens,
        output_tokens = output_tokens,
    }
end

return M
