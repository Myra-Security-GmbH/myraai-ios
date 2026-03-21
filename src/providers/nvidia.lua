-- providers/nvidia.lua — NVIDIA NIM (OpenAI-compatible)
-- Base URL: https://integrate.api.nvidia.com/v1

local openai = require("providers.openai")

local M = {}

local BASE_URL = "https://integrate.api.nvidia.com"

function M.base_url(ctx)
    return BASE_URL .. (ctx.provider_path or "/v1/chat/completions")
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. (api_key or ""),
        ["X-Request-Id"]  = ctx.request_id or "",
    }
end

M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
