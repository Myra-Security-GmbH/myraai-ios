-- middleware/quota.lua — hard-stop when gateway budget_usd is exceeded
-- Budget counter lives in state; reset is a manual admin operation.

local state  = require("state")
local errors = require("core.errors")

local M = {}

function M.run(ctx)
    local budget = ctx.gateway_config.budget_usd
    if not budget then return end  -- no budget cap configured

    -- counter is stored in micro-dollars (cost * 1e6) to avoid float precision loss
    local spent_micro  = state.counter_get("budget:" .. ctx.gateway_id)
    local budget_micro = budget * 1e6
    if spent_micro >= budget_micro then
        errors.send("QUOTA_EXCEEDED",
            string.format("Budget $%.4f exceeded (spent $%.4f)",
                          budget, spent_micro / 1e6))
    end
end

return M
