-- core/context.lua — per-request context object stored in ngx.ctx
local M = {}

-- Initialise a fresh context for the current request.
-- Called once at the start of the access phase.
function M.init()
    local ctx = ngx.ctx

    -- Resolved from URL path by middleware/tenant.lua
    ctx.tenant_id      = nil    -- UUID string
    ctx.tenant_slug    = nil
    ctx.gateway_id     = nil    -- UUID string
    ctx.gateway_slug   = nil
    ctx.gateway_config = nil    -- merged config table
    ctx.provider       = nil    -- e.g. "openai", "anthropic"
    ctx.provider_path  = nil    -- path segment after provider name
    ctx.is_compat      = false  -- true when using /compat/ unified endpoint

    -- Set by middleware/auth.lua
    ctx.token_id     = nil
    ctx.token_scopes = {}

    -- Set by middleware/request_id.lua
    ctx.request_id = nil

    -- Set by middleware/transform.lua
    ctx.raw_request_body  = nil   -- raw JSON string (may be scrubbed by guardrails)
    ctx.request_body      = nil   -- parsed Lua table
    ctx.model             = nil   -- normalised model name
    ctx.skip_log          = false -- set by x-aig-collect-log: false
    ctx.skip_log_payload  = false -- set by x-aig-collect-log-payload: false

    -- Set by middleware/routing.lua
    ctx.fallback_chain = {}

    -- Set by middleware/byok.lua
    ctx.provider_api_key = nil

    -- Set by middleware/cache_check.lua
    ctx.cache_key = nil
    ctx.cache_hit = false

    -- Set by middleware/upstream.lua
    ctx.response_body              = nil
    ctx.input_tokens               = 0
    ctx.output_tokens              = 0
    ctx.cache_creation_tokens      = 0
    ctx.cache_read_tokens          = 0
    ctx.provider_status            = nil
    ctx.is_streaming               = false
    ctx.upstream_latency_ms        = nil  -- TTFB from provider
    ctx.time_to_first_token_ms     = nil  -- streaming only
    ctx.upstream_attempts          = nil  -- total call attempts (1 = first try succeeded)
    ctx.fallback_provider          = nil  -- set when a fallback provider was used
    ctx.fallback_model             = nil
    ctx.provider_request_id        = nil  -- x-request-id from provider response

    -- Set by middleware/guardrails_response.lua
    ctx.guardrail_response_blocked = nil

    -- Set by middleware/cost.lua
    ctx.cost_usd = 0

    -- Timing (set here; used by observability)
    ctx.start_ms = ngx.now() * 1000

    -- Custom metadata from x-aig-meta-* headers
    ctx.meta = {}

    -- Accumulated extra log fields (appended by any middleware)
    ctx.log_fields = {}
end

-- Convenience: merge extra fields into log_fields
function M.log(fields)
    local lf = ngx.ctx.log_fields
    for k, v in pairs(fields) do
        lf[k] = v
    end
end

-- Latency in ms since request start
function M.latency_ms()
    return math.floor(ngx.now() * 1000 - (ngx.ctx.start_ms or 0))
end

return M
