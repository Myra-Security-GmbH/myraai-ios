-- middleware/quota.lua — hard-stop when gateway budget_usd is exceeded
-- Budget counter lives in state; reset is a manual admin operation.

local state  = require("state")
local errors = require("core.errors")

local M = {}

function M.run(ctx)
    -- Per-token budget check (takes priority over gateway budget)
    if ctx.token_budget_usd and ctx.token_id then
        local spent_micro  = state.counter_get("budget:token:" .. ctx.token_id) or 0
        local budget_micro = ctx.token_budget_usd * 1e6
        ctx.log_fields.token_quota_remaining = math.max(0, (budget_micro - spent_micro) / 1e6)
        if spent_micro >= budget_micro then
            ctx.log_fields.blocked_by   = "quota"
            ctx.log_fields.block_reason = string.format("token spent $%.4f of $%.4f",
                                              spent_micro / 1e6, ctx.token_budget_usd)
            errors.send("QUOTA_EXCEEDED",
                string.format("Token budget $%.4f exceeded (spent $%.4f)",
                              ctx.token_budget_usd, spent_micro / 1e6))
        end
    end

    -- Per-gateway budget check
    local budget = ctx.gateway_config.budget_usd
    if not budget then return end  -- no budget cap configured

    -- counter is stored in micro-dollars (cost * 1e6) to avoid float precision loss
    local spent_micro  = state.counter_get("budget:" .. ctx.gateway_id)
    local budget_micro = budget * 1e6
    ctx.log_fields.quota_remaining = math.max(0, (budget_micro - spent_micro) / 1e6)
    if spent_micro >= budget_micro then
        ctx.log_fields.blocked_by   = "quota"
        ctx.log_fields.block_reason = string.format("spent $%.4f of $%.4f",
                                          spent_micro / 1e6, budget)
        errors.send("QUOTA_EXCEEDED",
            string.format("Budget $%.4f exceeded (spent $%.4f)",
                          budget, spent_micro / 1e6))
    end
end

return M
