-- providers/xai.lua — xAI Grok (OpenAI-compatible wire format)

local openai = require("providers.openai")

local M = {}

local BASE_URL = "https://api.x.ai"

function M.base_url(ctx)
    return BASE_URL .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["X-Request-Id"]  = ctx.request_id or "",
    }
end

M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
