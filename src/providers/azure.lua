-- providers/azure.lua — Azure OpenAI Service
--
-- URL format:
--   https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version={version}
--
-- Auth: "api-key" header (not Authorization: Bearer).
-- Deployment name = model name unless gateway_config.azure_deployment overrides it.
-- Required config keys: azure_resource, azure_api_version (default: 2024-10-21)

local openai = require("providers.openai")

local M = {}

local DEFAULT_API_VERSION = "2024-10-21"

function M.base_url(ctx)
    local cfg        = ctx.gateway_config or {}
    local resource   = cfg.azure_resource or "my-resource"
    local deployment = cfg.azure_deployment or ctx.model or "gpt-4o"
    local version    = cfg.azure_api_version or DEFAULT_API_VERSION
    return "https://" .. resource
        .. ".openai.azure.com/openai/deployments/" .. deployment
        .. "/chat/completions?api-version=" .. version
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"] = "application/json",
        ["api-key"]      = api_key,
        ["X-Request-Id"] = ctx.request_id or "",
    }
end

M.build_request   = openai.build_request
M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
