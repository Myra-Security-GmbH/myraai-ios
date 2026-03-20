-- state/redis.lua — Redis backend (production swap for shared_dict.lua)
-- Exposes the same interface as state/shared_dict.lua.
-- Stub: implement when switching state = "redis" in config.

local M = {}

local function not_impl(name)
    return function()
        error("state/redis: " .. name .. " not yet implemented")
    end
end

M.cache_get         = not_impl("cache_get")
M.cache_set         = not_impl("cache_set")
M.cache_del         = not_impl("cache_del")
M.rate_limit_check  = not_impl("rate_limit_check")
M.counter_incr      = not_impl("counter_incr")
M.counter_get       = not_impl("counter_get")
M.byok_get          = not_impl("byok_get")
M.byok_set          = not_impl("byok_set")
M.config_get        = not_impl("config_get")
M.config_set        = not_impl("config_set")
M.metrics_incr      = not_impl("metrics_incr")

return M
