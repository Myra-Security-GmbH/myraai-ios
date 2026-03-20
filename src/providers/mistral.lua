-- providers/mistral.lua — Mistral AI (OpenAI-compatible wire format)

local json   = require("utils.json")
local openai = require("providers.openai")

local M = {}

local BASE_URL = "https://api.mistral.ai"

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

-- Mistral uses the same wire format as OpenAI
M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
