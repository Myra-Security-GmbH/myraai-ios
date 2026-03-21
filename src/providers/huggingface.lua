-- providers/huggingface.lua — Hugging Face Inference API (OpenAI-compatible)
--
-- Two URL modes:
--   Serverless:  https://api-inference.huggingface.co/models/{model}/v1/chat/completions
--   Dedicated:   {gateway_config.hf_endpoint}/v1/chat/completions
--
-- Auth: Authorization: Bearer {token}

local openai = require("providers.openai")

local M = {}

local DEFAULT_BASE = "https://api-inference.huggingface.co"

function M.base_url(ctx)
    local cfg = ctx.gateway_config or {}
    if cfg.hf_endpoint and cfg.hf_endpoint ~= "" then
        -- Dedicated Inference Endpoint — already has /v1 path
        return cfg.hf_endpoint .. (ctx.provider_path or "/v1/chat/completions")
    end
    -- Serverless: model name goes in the URL path
    local model = ctx.model or ""
    return DEFAULT_BASE .. "/models/" .. model .. "/v1/chat/completions"
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
