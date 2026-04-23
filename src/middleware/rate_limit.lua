-- middleware/rate_limit.lua — per-gateway and per-token sliding-window rate limiting
--
-- Gateway-level config (in gateway_config.rate_limit):
--   { requests = 100, window_sec = 60 }   -- 100 req/min, shared by all tokens
--
-- Token-level config (in auth_token.rate_limit JSON column):
--   { requests = 20, window_sec = 60 }    -- per-token override
--
-- Gateway limit is checked first; if the token has its own limit it is
-- checked independently (a token can be blocked even if the gateway is not).

local state  = require("state")
local errors = require("core.errors")
local json   = require("utils.json")

local M = {}

local function check_limit(key, window_sec, limit, label)
    local allowed, count = state.rate_limit_check(key, window_sec, limit)
    if not allowed then
        ngx.log(ngx.WARN, "rate_limit: blocked (", label, ") ",
                count, "/", limit, " per ", window_sec, "s")
        return false, count
    end
    return true, count
end

function M.run(ctx)
    -- ── Gateway-level rate limit ────────────────────────────────────────────
    local gw_rl = ctx.gateway_config.rate_limit
    if type(gw_rl) == "table" then
        local limit      = gw_rl.requests  or 100
        local window_sec = gw_rl.window_sec or 60
        local allowed, count = check_limit("rl:" .. ctx.gateway_id, window_sec, limit,
                                           "gateway:" .. ctx.gateway_id)
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
            return
        end
        ngx.header["X-RateLimit-Limit"]     = limit
        ngx.header["X-RateLimit-Remaining"] = math.max(0, limit - count)
    end

    -- ── Per-token rate limit ────────────────────────────────────────────────
    if ctx.token_id and ctx.token_rate_limit then
        local token_rl = type(ctx.token_rate_limit) == "table"
                         and ctx.token_rate_limit
                         or  json.decode(ctx.token_rate_limit)
        if token_rl and token_rl.requests then
            local limit      = token_rl.requests
            local window_sec = token_rl.window_sec or 60
            local allowed, count = check_limit(
                "rl:token:" .. ctx.token_id, window_sec, limit,
                "token:" .. ctx.token_id)
            if not allowed then
                ctx.log_fields = ctx.log_fields or {}
                ctx.log_fields.blocked_by   = "rate_limit"
                ctx.log_fields.block_reason = "token: " .. count .. "/" .. limit ..
                                              " per " .. window_sec .. "s"
                ngx.header["X-RateLimit-Limit"]     = limit
                ngx.header["X-RateLimit-Remaining"] = 0
                ngx.header["Retry-After"]           = window_sec
                errors.send("RATE_LIMITED",
                    "Token rate limit: " .. count .. "/" .. limit ..
                    " requests per " .. window_sec .. "s")
                return
            end
            -- Token limit headers shadow gateway headers when stricter
            ngx.header["X-RateLimit-Limit"]     = limit
            ngx.header["X-RateLimit-Remaining"] = math.max(0, limit - count)
        end
    end
end

return M
