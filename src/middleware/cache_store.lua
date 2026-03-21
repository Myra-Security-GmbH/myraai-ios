-- middleware/cache_store.lua — store a successful response in the exact-match cache
-- Only stores non-streaming 200 responses when cache_ttl > 0 and cache_key is set.

local state = require("state")
local json  = require("utils.json")

local M = {}

function M.run(ctx)
    if ctx.is_streaming    then return end  -- never cache streaming
    if ctx.cache_hit       then return end  -- already came from cache
    if not ctx.cache_key   then return end  -- no key (stream=true or caching off)
    if not ctx.response_body then return end

    local ttl = ctx.gateway_config.cache_ttl or 0
    if ttl <= 0 then return end

    if (ctx.provider_status or 0) ~= 200 then return end

    local entry = json.encode({ body = ctx.response_body, cost_usd = ctx.cost_usd or 0 })
    if entry then
        state.cache_set(ctx.cache_key, entry, ttl)
    end
end

return M
