-- middleware/quota.lua — hard-stop when budget_usd is exceeded for the current period
-- Three scopes checked in order: per-token → per-tenant → per-gateway.
-- Spend is read from the persistent spend_ledger via a 30-second shared-dict cache.
-- Cache is invalidated by cost.lua immediately after each spend write.

local storage    = require("storage")
local budget_lib = require("utils.budget")
local state      = require("state")
local errors     = require("core.errors")
local webhook    = require("utils.webhook")

local CACHE_TTL = 30  -- seconds

local M = {}

local function get_spend_cached(entity_type, entity_id, period)
    local key = "spend:" .. entity_type .. ":" .. entity_id .. ":" .. period
    local cached = state.cache_get(key)
    if cached ~= nil then return cached end
    local micro = storage.get_spend(entity_type, entity_id, period)
    state.cache_set(key, micro, CACHE_TTL)
    return micro
end

local function fire_budget_webhook(ctx, scope, budget, spent)
    if ctx.gateway_config and type(ctx.gateway_config.webhooks) == "table" then
        pcall(webhook.fire, ctx.gateway_config.webhooks, "budget_exceeded", {
            scope      = scope,
            budget_usd = budget,
            spent_usd  = spent,
            period     = scope,
        }, { gateway_id = ctx.gateway_id, tenant_id = ctx.tenant_id })
    end
end

function M.run(ctx)
    ctx.log_fields = ctx.log_fields or {}

    -- ctx.token_id, ctx.token_budget_usd, ctx.token_budget_period set by auth.lua

    -- ── Per-token budget ─────────────────────────────────────────────────────
    if ctx.token_budget_usd and ctx.token_id then
        local period      = budget_lib.current_period(ctx.token_budget_period or "monthly")
        local spent_micro = get_spend_cached("token", ctx.token_id, period)
        local cap_micro   = math.floor(ctx.token_budget_usd * 1e6)
        ctx.log_fields.token_quota_remaining = math.max(0, (cap_micro - spent_micro) / 1e6)
        if spent_micro >= cap_micro then
            fire_budget_webhook(ctx, "token", ctx.token_budget_usd, spent_micro / 1e6)
            ctx.log_fields.blocked_by   = "quota"
            ctx.log_fields.block_reason = string.format(
                "token budget $%.4f/%s exceeded (spent $%.4f)",
                ctx.token_budget_usd, period, spent_micro / 1e6)
            errors.send("QUOTA_EXCEEDED",
                string.format("Token budget $%.4f exceeded (spent $%.4f). " ..
                              "Adjust budget_usd on the auth token (PATCH /admin/v1/tokens/%s) " ..
                              "or reset spend (DELETE /admin/v1/tokens/%s/budget).",
                              ctx.token_budget_usd, spent_micro / 1e6,
                              ctx.token_id, ctx.token_id))
        end
    end

    -- ── Per-tenant budget ────────────────────────────────────────────────────
    local tenant_budget = ctx.gateway_config.tenant_budget_usd
    if tenant_budget and ctx.tenant_id then
        local period      = budget_lib.current_period(
            ctx.gateway_config.tenant_budget_period or "monthly")
        local spent_micro = get_spend_cached("tenant", ctx.tenant_id, period)
        local cap_micro   = math.floor(tenant_budget * 1e6)
        ctx.log_fields.tenant_quota_remaining = math.max(0, (cap_micro - spent_micro) / 1e6)
        if spent_micro >= cap_micro then
            fire_budget_webhook(ctx, "tenant", tenant_budget, spent_micro / 1e6)
            ctx.log_fields.blocked_by   = "quota"
            ctx.log_fields.block_reason = string.format(
                "tenant budget $%.4f/%s exceeded (spent $%.4f)",
                tenant_budget, period, spent_micro / 1e6)
            errors.send("QUOTA_EXCEEDED",
                string.format("Tenant budget $%.4f exceeded (spent $%.4f). " ..
                              "Adjust budget_usd on the tenant (PATCH /admin/v1/tenants/%s) " ..
                              "or reset spend (DELETE /admin/v1/tenants/%s/budget).",
                              tenant_budget, spent_micro / 1e6,
                              ctx.tenant_id, ctx.tenant_id))
        end
    end

    -- ── Per-gateway budget ───────────────────────────────────────────────────
    local gw_budget = ctx.gateway_config.budget_usd
    if not gw_budget then return end

    local period      = budget_lib.current_period(
        ctx.gateway_config.budget_period or "monthly")
    local spent_micro = get_spend_cached("gateway", ctx.gateway_id, period)
    local cap_micro   = math.floor(gw_budget * 1e6)
    ctx.log_fields.quota_remaining = math.max(0, (cap_micro - spent_micro) / 1e6)
    if spent_micro >= cap_micro then
        fire_budget_webhook(ctx, "gateway", gw_budget, spent_micro / 1e6)
        ctx.log_fields.blocked_by   = "quota"
        ctx.log_fields.block_reason = string.format(
            "gateway budget $%.4f/%s exceeded (spent $%.4f)",
            gw_budget, period, spent_micro / 1e6)
        errors.send("QUOTA_EXCEEDED",
            string.format("Gateway budget $%.4f exceeded (spent $%.4f). " ..
                          "Adjust budget_usd in the gateway config (PATCH /admin/v1/gateways/%s) " ..
                          "or reset spend (DELETE /admin/v1/gateways/%s/budget).",
                          gw_budget, spent_micro / 1e6,
                          ctx.gateway_id, ctx.gateway_id))
    end
end

return M
