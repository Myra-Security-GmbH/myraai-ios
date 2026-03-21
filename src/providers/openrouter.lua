-- providers/openrouter.lua — OpenRouter (OpenAI-compatible wire format)
-- Requires HTTP-Referer and X-Title headers per OpenRouter API policy.

local openai = require("providers.openai")

local M = {}

local BASE_URL = "https://openrouter.ai/api"

function M.base_url(ctx)
    return BASE_URL .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
        ["HTTP-Referer"]  = "https://ai-gateway",
        ["X-Title"]       = "AI Gateway",
        ["X-Request-Id"]  = ctx.request_id or "",
    }
end

M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
