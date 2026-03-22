-- providers/cohere.lua — Cohere v2 Chat API adapter
--
-- Wire format differs from OpenAI:
--   POST https://api.cohere.com/v2/chat
--   Response: body.message.content[].text
--   Usage: body.usage.billed_units.{input_tokens, output_tokens}
--
-- SSE streaming events:
--   content-delta  → body.delta.text
--   message-end    → body.delta.usage.billed_units.{input_tokens, output_tokens}

local json = require("utils.json")

local M = {}

local BASE_URL = "https://api.cohere.com"

function M.base_url(ctx)
    return BASE_URL .. "/v2/chat"
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["X-Request-Id"]  = ctx.request_id or "",
    }
end

-- Convert OpenAI chat/completions body to Cohere v2 chat format.
-- Cohere v2 accepts the same role names (system/user/assistant) and message
-- structure, so no role translation is required.
function M.build_request(ctx)
    -- Embedding models cannot be used with the chat endpoint.
    if ctx.model and ctx.model:lower():find("embed", 1, true) then
        ngx.log(ngx.WARN, "cohere: model '", ctx.model,
                "' is an embedding model and cannot be used for chat completions")
    end

    local src = ctx.request_body

    local messages = {}
    for _, msg in ipairs(src.messages or {}) do
        messages[#messages + 1] = { role = msg.role, content = msg.content }
    end

    local body = {
        model    = ctx.model,
        messages = messages,
        stream   = src.stream or false,
    }
    if src.max_tokens  then body.max_tokens     = src.max_tokens  end
    if src.temperature then body.temperature    = src.temperature end
    if src.top_p       then body.p              = src.top_p       end
    if src.stop        then
        body.stop_sequences = type(src.stop) == "table" and src.stop or { src.stop }
    end

    return json.sanitize_surrogates(json.encode(body))
end

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then return nil, "json decode failed" end

    -- Error response: {"message": "..."}
    if body.message and type(body.message) == "string" then
        return nil, body.message
    end

    local content = ""
    local msg = (type(body.message) == "table") and body.message or {}
    for _, block in ipairs(msg.content or {}) do
        if block.type == "text" then
            content = content .. (block.text or "")
        end
    end

    local bu = (body.usage and body.usage.billed_units) or {}
    return {
        content       = content,
        input_tokens  = bu.input_tokens  or 0,
        output_tokens = bu.output_tokens or 0,
        raw           = body,
    }
end

-- Cohere SSE streaming events (v2):
--   {"type":"content-delta","index":0,"delta":{"type":"text-delta","text":"Hello"}}
--   {"type":"message-end","delta":{"finish_reason":"COMPLETE",
--     "usage":{"billed_units":{"input_tokens":5,"output_tokens":2}}}}
function M.parse_sse_chunk(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end

    local chunk = json.decode(data)
    if not chunk then return nil end

    local delta = ""
    if chunk.type == "content-delta"
       and chunk.delta
       and chunk.delta.type == "text-delta" then
        delta = chunk.delta.text or ""
    end

    local done = (chunk.type == "message-end")

    local input_tokens, output_tokens
    if done and chunk.delta and chunk.delta.usage then
        local bu = chunk.delta.usage.billed_units or {}
        input_tokens  = bu.input_tokens
        output_tokens = bu.output_tokens
    end

    return {
        delta         = delta,
        done          = done,
        input_tokens  = input_tokens,
        output_tokens = output_tokens,
    }
end

return M
