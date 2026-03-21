-- providers/ollama.lua — Ollama local model server (OpenAI-compatible wire format)
-- Base URL is read from gateway_config.provider_base_urls.ollama; defaults to localhost.
-- Auth is optional: Ollama does not require a key by default.

local openai = require("providers.openai")

local M = {}

local DEFAULT_BASE = "http://localhost:11434"

function M.base_url(ctx)
    local base = (ctx.gateway_config
                  and ctx.gateway_config.provider_base_urls
                  and ctx.gateway_config.provider_base_urls.ollama)
                 or DEFAULT_BASE
    return base .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Request-Id"] = ctx.request_id or "",
    }
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    return headers
end

M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
