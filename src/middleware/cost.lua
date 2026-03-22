-- middleware/cost.lua — token counting and cost attribution
-- Increments the gateway's running spend counter in state.

local cost_table = require("observability.cost_table")
local state      = require("state")

local M = {}

function M.run(ctx)
    local input_t    = ctx.input_tokens          or 0
    local output_t   = ctx.output_tokens         or 0
    local cache_cre  = ctx.cache_creation_tokens or 0
    local cache_read = ctx.cache_read_tokens     or 0

    -- nil means pricing is unknown for this provider/model combination.
    -- We preserve nil rather than coercing to 0 so that callers can distinguish
    -- "zero cost" (free/local model) from "cost unknown" (missing price entry).
    local cost = cost_table.calculate(ctx.provider, ctx.model,
                                      input_t, output_t, cache_cre, cache_read)
    ctx.cost_usd = cost

    if cost and cost > 0 then
        -- Increment persistent budget counter (float stored as string * 1e6 int)
        -- Using integer micro-dollars to avoid float precision issues in shared_dict
        local micro = math.floor(cost * 1e6)
        state.counter_incr("budget:" .. ctx.gateway_id, micro)
        -- Per-tenant counter (checked by quota.lua against tenant.budget_usd)
        if ctx.tenant_id then
            state.counter_incr("budget:tenant:" .. ctx.tenant_id, micro)
        end
        -- Also increment per-token counter when the token has its own budget cap
        if ctx.token_id and ctx.token_budget_usd then
            state.counter_incr("budget:token:" .. ctx.token_id, micro)
        end
    end
end

return M
