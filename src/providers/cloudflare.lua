-- providers/cloudflare.lua — Cloudflare Workers AI (OpenAI-compatible)
--
-- URL: https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1/chat/completions
-- Auth: Authorization: Bearer {api_token}
-- Required config: cf_account_id

local openai = require("providers.openai")

local M = {}

local BASE = "https://api.cloudflare.com/client/v4/accounts"

function M.base_url(ctx)
    local cfg        = ctx.gateway_config or {}
    local account_id = cfg.cf_account_id or "ACCOUNT_ID"
    return BASE .. "/" .. account_id .. "/ai/v1/chat/completions"
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
