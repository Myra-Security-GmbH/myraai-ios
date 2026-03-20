-- middleware/cost.lua — token counting and cost attribution
-- Increments the gateway's running spend counter in state.

local cost_table = require("observability.cost_table")
local state      = require("state")

local M = {}

function M.run(ctx)
    local input_t  = ctx.input_tokens  or 0
    local output_t = ctx.output_tokens or 0

    local cost = cost_table.calculate(ctx.provider, ctx.model, input_t, output_t)
    ctx.cost_usd = cost

    if cost > 0 then
        -- Increment persistent budget counter (float stored as string * 1e6 int)
        -- Using integer micro-dollars to avoid float precision issues in shared_dict
        local micro = math.floor(cost * 1e6)
        state.counter_incr("budget:" .. ctx.gateway_id, micro)
    end
end

return M
