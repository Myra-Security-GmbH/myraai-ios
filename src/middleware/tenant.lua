-- middleware/tenant.lua — resolve tenant + gateway from the request URI
-- Expected URI:  /v1/{tenant_slug}/{gateway_slug}/{provider}/{...}
--   or compat:   /v1/{tenant_slug}/{gateway_slug}/compat/{...}
--
-- Sets on ctx:
--   tenant_slug, gateway_slug, provider, provider_path, is_compat
--   tenant_id, gateway_id, gateway_config (from DB/cache)

local config = require("core.config")
local errors = require("core.errors")

local M = {}

-- Providers we natively understand (anything else is rejected)
local KNOWN_PROVIDERS = {
    openai    = true,
    anthropic = true,
    gemini    = true,
    bedrock   = true,
    mistral   = true,
    groq      = true,
    cohere    = true,
    deepseek  = true,
    xai       = true,
    compat    = true,   -- unified OpenAI-compatible endpoint
}

function M.run(ctx)
    local uri = ngx.var.uri  -- e.g. /v1/acme/main/openai/chat/completions

    -- Strip leading /v1/
    local rest = uri:match("^/v1/(.+)$")
    if not rest then
        errors.send("INVALID_REQUEST", "URI must start with /v1/")
    end

    -- Split: tenant / gateway / provider / rest
    local tenant_slug, gateway_slug, provider, provider_path =
        rest:match("^([^/]+)/([^/]+)/([^/]+)(.*)$")

    if not tenant_slug or not gateway_slug or not provider then
        errors.send("INVALID_REQUEST",
            "URI must be /v1/{tenant}/{gateway}/{provider}/...")
    end

    provider = provider:lower()

    if not KNOWN_PROVIDERS[provider] then
        errors.send("INVALID_REQUEST", "Unknown provider: " .. provider)
    end

    ctx.tenant_slug   = tenant_slug
    ctx.gateway_slug  = gateway_slug
    ctx.provider      = provider
    ctx.provider_path = provider_path or ""
    ctx.is_compat     = (provider == "compat")

    -- Load gateway config (cached)
    local gw_config = config.get_gateway(tenant_slug, gateway_slug)
    if not gw_config then return end  -- errors.send already called

    ctx.tenant_id    = gw_config.tenant_id
    ctx.gateway_id   = gw_config.gateway_id
    ctx.gateway_config = gw_config
end

return M
