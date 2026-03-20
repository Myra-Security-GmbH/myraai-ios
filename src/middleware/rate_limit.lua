-- middleware/rate_limit.lua — per-gateway sliding-window rate limiting
-- Config (in gateway_config.rate_limit):
--   { requests = 100, window_sec = 60 }   -- 100 req/min
-- Keyed by gateway_id (all tokens on a gateway share the limit).

local state  = require("state")
local errors = require("core.errors")

local M = {}

function M.run(ctx)
    local rl = ctx.gateway_config.rate_limit
    if not rl then return end  -- rate limiting disabled for this gateway

    local limit      = rl.requests  or 100
    local window_sec = rl.window_sec or 60

    local key = "rl:" .. ctx.gateway_id

    local allowed, count = state.rate_limit_check(key, window_sec, limit)
    if not allowed then
        ctx.log_fields = ctx.log_fields or {}
        ctx.log_fields.blocked_by   = "rate_limit"
        ctx.log_fields.block_reason = count .. "/" .. limit .. " per " .. window_sec .. "s"
        ngx.header["X-RateLimit-Limit"]     = limit
        ngx.header["X-RateLimit-Remaining"] = 0
        ngx.header["Retry-After"]           = window_sec
        errors.send("RATE_LIMITED",
            "Rate limit: " .. count .. "/" .. limit ..
            " requests per " .. window_sec .. "s")
    end

    ngx.header["X-RateLimit-Limit"]     = limit
    ngx.header["X-RateLimit-Remaining"] = math.max(0, limit - count)
end

return M
