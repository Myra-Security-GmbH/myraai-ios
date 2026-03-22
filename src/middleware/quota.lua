-- middleware/quota.lua — hard-stop when budget_usd is exceeded
-- Three scopes checked in order: per-token → per-tenant → per-gateway.
-- Budget counters live in state; reset via DELETE /admin/v1/.../budget.

local state   = require("state")
local errors  = require("core.errors")
local webhook = require("utils.webhook")

local M = {}

local function fire_budget_webhook(ctx, scope, budget, spent)
    webhook.fire(ctx.gateway_config.webhooks, "budget_exceeded", {
        scope      = scope,
        budget_usd = budget,
        spent_usd  = spent,
    }, { gateway_id = ctx.gateway_id, tenant_id = ctx.tenant_id })
end

function M.run(ctx)
    -- ctx.log_fields is initialised by context.lua before the pipeline runs;
    -- guard here for defensive consistency with other middlewares.
    ctx.log_fields = ctx.log_fields or {}

    -- ctx.token_id and ctx.token_budget_usd are set by middleware/auth.lua.
    -- quota.lua must run after auth.lua in the pipeline.

    -- ── Per-token budget ────────────────────────────────────────────────────
    if ctx.token_budget_usd and ctx.token_id then
        local spent_micro  = state.counter_get("budget:token:" .. ctx.token_id) or 0
        local budget_micro = ctx.token_budget_usd * 1e6
        ctx.log_fields.token_quota_remaining = math.max(0, (budget_micro - spent_micro) / 1e6)
        if spent_micro >= budget_micro then
            fire_budget_webhook(ctx, "token", ctx.token_budget_usd, spent_micro / 1e6)
            ctx.log_fields.blocked_by   = "quota"
            ctx.log_fields.block_reason = string.format("token spent $%.4f of $%.4f",
                                              spent_micro / 1e6, ctx.token_budget_usd)
            errors.send("QUOTA_EXCEEDED",
                string.format("Token budget $%.4f exceeded (spent $%.4f)",
                              ctx.token_budget_usd, spent_micro / 1e6))
        end
    end

    -- ── Per-tenant budget ───────────────────────────────────────────────────
    local tenant_budget = ctx.gateway_config.tenant_budget_usd
    if tenant_budget and ctx.tenant_id then
        local spent_micro  = state.counter_get("budget:tenant:" .. ctx.tenant_id) or 0
        local budget_micro = tenant_budget * 1e6
        ctx.log_fields.tenant_quota_remaining = math.max(0, (budget_micro - spent_micro) / 1e6)
        if spent_micro >= budget_micro then
            fire_budget_webhook(ctx, "tenant", tenant_budget, spent_micro / 1e6)
            ctx.log_fields.blocked_by   = "quota"
            ctx.log_fields.block_reason = string.format("tenant spent $%.4f of $%.4f",
                                              spent_micro / 1e6, tenant_budget)
            errors.send("QUOTA_EXCEEDED",
                string.format("Tenant budget $%.4f exceeded (spent $%.4f)",
                              tenant_budget, spent_micro / 1e6))
        end
    end

    -- ── Per-gateway budget ──────────────────────────────────────────────────
    local budget = ctx.gateway_config.budget_usd
    if not budget then return end

    local spent_micro  = state.counter_get("budget:" .. ctx.gateway_id) or 0
    local budget_micro = budget * 1e6
    ctx.log_fields.quota_remaining = math.max(0, (budget_micro - spent_micro) / 1e6)
    if spent_micro >= budget_micro then
        fire_budget_webhook(ctx, "gateway", budget, spent_micro / 1e6)
        ctx.log_fields.blocked_by   = "quota"
        ctx.log_fields.block_reason = string.format("spent $%.4f of $%.4f",
                                          spent_micro / 1e6, budget)
        errors.send("QUOTA_EXCEEDED",
            string.format("Budget $%.4f exceeded (spent $%.4f)",
                          budget, spent_micro / 1e6))
    end
end

return M
