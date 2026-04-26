-- middleware/cost.lua — token counting and cost attribution
-- Records spend in the persistent spend_ledger (SQLite) and invalidates
-- the 30-second shared-dict read cache used by quota.lua.

local cost_table = require("observability.cost_table")
local storage    = require("storage")
local budget_lib = require("utils.budget")
local state      = require("state")

local M = {}

function M.run(ctx)
    local input_t     = ctx.input_tokens             or 0
    local output_t    = ctx.output_tokens            or 0
    local cache_cre   = ctx.cache_creation_tokens    or 0
    local cache_cre1h = ctx.cache_creation_1h_tokens or 0
    local cache_read  = ctx.cache_read_tokens        or 0
    local cache_del   = ctx.cache_deletion_tokens    or 0

    -- nil means pricing is unknown for this provider/model combination.
    -- We preserve nil rather than coercing to 0 so callers can distinguish
    -- "zero cost" (free/local model) from "cost unknown" (missing price entry).
    local cost = cost_table.calculate(ctx.provider, ctx.model,
                                      input_t, output_t, cache_cre, cache_cre1h, cache_read, cache_del)
    ctx.cost_usd = cost

    if not cost or cost <= 0 then return end

    local micro = math.max(1, math.floor(cost * 1e6))

    -- ── Per-gateway ──────────────────────────────────────────────────────────
    local gw_period = budget_lib.current_period(
        ctx.gateway_config and ctx.gateway_config.budget_period or "monthly")
    local gw_ok, gw_err = pcall(storage.incr_spend, "gateway", ctx.gateway_id, gw_period, micro)
    if not gw_ok then
        ngx.log(ngx.ERR, "cost: incr_spend gateway failed: ", tostring(gw_err), " gw=", ctx.gateway_id)
    end
    state.cache_del("spend:gateway:" .. ctx.gateway_id .. ":" .. gw_period)

    -- ── Per-tenant ───────────────────────────────────────────────────────────
    if ctx.tenant_id then
        local t_period = budget_lib.current_period(
            ctx.gateway_config and ctx.gateway_config.tenant_budget_period or "monthly")
        local t_ok, t_err = pcall(storage.incr_spend, "tenant", ctx.tenant_id, t_period, micro)
        if not t_ok then
            ngx.log(ngx.ERR, "cost: incr_spend tenant failed: ", tostring(t_err), " tenant=", ctx.tenant_id)
        end
        state.cache_del("spend:tenant:" .. ctx.tenant_id .. ":" .. t_period)
    end

    -- ── Per-token ────────────────────────────────────────────────────────────
    if ctx.token_id and ctx.token_budget_usd then
        local tk_period = budget_lib.current_period(ctx.token_budget_period or "monthly")
        local tk_ok, tk_err = pcall(storage.incr_spend, "token", ctx.token_id, tk_period, micro)
        if not tk_ok then
            ngx.log(ngx.ERR, "cost: incr_spend token failed: ", tostring(tk_err), " token=", ctx.token_id)
        end
        state.cache_del("spend:token:" .. ctx.token_id .. ":" .. tk_period)
    end
end

return M
