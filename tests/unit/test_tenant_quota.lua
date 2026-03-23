-- tests/unit/test_tenant_quota.lua
-- Tests for per-tenant budget enforcement in middleware/quota.lua
-- and tenant counter increment in middleware/cost.lua
-- Run with: resty tests/runner.lua tests/unit/test_tenant_quota.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls = {}
_G.ngx = {
    log    = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    timer  = { at = function(_, fn, ...) fn(nil, ...) end },
    WARN = 1, INFO = 2, ERR = 0,
    status = 200,
    exit   = function(c) error("ngx.exit("..c..")") end,
    req    = { read_body = function() end },
    ctx    = {},
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ─── module stubs ──────────────────────────────────────────────────────────
local ALL_MODS = { "middleware.quota", "middleware.cost", "state", "storage",
                   "utils.budget", "core.errors", "utils.webhook",
                   "observability.cost_table" }

local function clear_all()
    for _, n in ipairs(ALL_MODS) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- _spend_read:    what storage.get_spend returns (pre-set per test)
--   key: entity_type .. ":" .. entity_id   e.g. "tenant:t1"
-- _spend_written: what storage.incr_spend accumulates
--   key: entity_type .. ":" .. entity_id
local _spend_read    = {}
local _spend_written = {}
local _webhook_calls = {}
local _cache         = {}

local function setup_mocks()
    package.preload["utils.budget"] = function()
        return { current_period = function() return "2026-03" end }
    end

    package.preload["storage"] = function()
        return {
            get_spend = function(entity_type, entity_id, _period)
                return _spend_read[entity_type .. ":" .. entity_id] or 0
            end,
            incr_spend = function(entity_type, entity_id, _period, micro)
                local k = entity_type .. ":" .. entity_id
                _spend_written[k] = (_spend_written[k] or 0) + micro
            end,
        }
    end

    package.preload["state"] = function()
        return {
            cache_get = function(k)        return _cache[k] end,
            cache_set = function(k, v, _t) _cache[k] = v end,
            cache_del = function(k)        _cache[k] = nil end,
        }
    end

    package.preload["core.errors"] = function()
        return { send = function(code, msg) error("QUOTA:" .. tostring(msg)) end }
    end

    package.preload["utils.webhook"] = function()
        return {
            fire = function(cfg, event, data, info)
                if not cfg or type(cfg) ~= "table" then return end
                if not cfg.url or cfg.url == "" then return end
                _webhook_calls[#_webhook_calls+1] = { cfg = cfg, event = event, data = data, info = info }
            end,
        }
    end

    package.preload["observability.cost_table"] = function()
        return { calculate = function() return 0.01 end }
    end
end

local function reset()
    _spend_read    = {}
    _spend_written = {}
    _webhook_calls = {}
    _cache         = {}
    _log_calls     = {}
    clear_all()
    setup_mocks()
end

-- ─── helpers ───────────────────────────────────────────────────────────────
local function make_ctx(opts)
    opts = opts or {}
    return {
        gateway_id   = opts.gateway_id   or "gw1",
        tenant_id    = opts.tenant_id    or "t1",
        token_id     = opts.token_id,
        token_budget_usd = opts.token_budget_usd,
        provider     = "openai",
        model        = "gpt-4o",
        input_tokens  = opts.input_tokens  or 100,
        output_tokens = opts.output_tokens or 50,
        cache_creation_tokens = 0,
        cache_read_tokens     = 0,
        gateway_config = opts.gateway_config or {},
        log_fields     = {},
    }
end

-- ─── cost.lua: tenant counter ──────────────────────────────────────────────
describe("cost.run: tenant counter", function()
    before_each(reset)

    it("increments budget:tenant:<tenant_id> when cost > 0", function()
        local cost = require("middleware.cost")
        local ctx = make_ctx()
        cost.run(ctx)
        assert.truthy((_spend_written["tenant:t1"] or 0) > 0)
    end)

    it("increments gateway and tenant spend independently", function()
        local cost = require("middleware.cost")
        local ctx = make_ctx()
        cost.run(ctx)
        assert.truthy((_spend_written["gateway:gw1"] or 0) > 0)
        assert.truthy((_spend_written["tenant:t1"]   or 0) > 0)
    end)

    it("does not increment tenant counter when tenant_id is nil", function()
        local cost = require("middleware.cost")
        local ctx = make_ctx()
        ctx.tenant_id = nil
        cost.run(ctx)
        local found = false
        for k in pairs(_spend_written) do
            if k:find("tenant:") then found = true end
        end
        assert.falsy(found)
    end)
end)

-- ─── quota.lua: per-tenant budget ──────────────────────────────────────────
describe("quota.run: per-tenant budget", function()
    before_each(reset)

    it("passes when no tenant_budget_usd configured", function()
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = {} })
        quota.run(ctx)   -- no error
    end)

    it("passes when tenant spend is below budget", function()
        _spend_read["tenant:t1"] = 50000  -- $0.05 spent
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = { tenant_budget_usd = 1.0 } })
        quota.run(ctx)   -- no error
    end)

    it("blocks when tenant spend meets budget", function()
        _spend_read["tenant:t1"] = 1000000  -- $1.00 spent = budget
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = { tenant_budget_usd = 1.0 } })
        local ok, err = pcall(quota.run, ctx)
        assert.falsy(ok)
        assert.match("QUOTA", err)
        assert.equal("quota", ctx.log_fields.blocked_by)
    end)

    it("fires budget_exceeded webhook on tenant block", function()
        _spend_read["tenant:t1"] = 1000000
        local quota = require("middleware.quota")
        local wh = { url = "http://hook.test/wh", events = {"budget_exceeded"} }
        local ctx = make_ctx({ gateway_config = { tenant_budget_usd = 1.0, webhooks = wh } })
        pcall(quota.run, ctx)
        assert.equal(1, #_webhook_calls)
        assert.equal("budget_exceeded", _webhook_calls[1].event)
        assert.equal("tenant", _webhook_calls[1].data.scope)
    end)

    it("sets tenant_quota_remaining log field", function()
        _spend_read["tenant:t1"] = 500000  -- $0.50
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = { tenant_budget_usd = 1.0 } })
        quota.run(ctx)
        assert.near(0.5, ctx.log_fields.tenant_quota_remaining, 0.001)
    end)

    it("tenant block does not fire webhook when no webhook configured", function()
        _spend_read["tenant:t1"] = 2000000
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = { tenant_budget_usd = 1.0 } })
        pcall(quota.run, ctx)
        assert.equal(0, #_webhook_calls)
    end)
end)

-- ─── quota.lua: gateway budget still works ─────────────────────────────────
describe("quota.run: gateway budget unaffected", function()
    before_each(reset)

    it("blocks when gateway spend meets budget", function()
        _spend_read["gateway:gw1"] = 500000  -- $0.50
        local quota = require("middleware.quota")
        local ctx = make_ctx({ gateway_config = { budget_usd = 0.5 } })
        local ok, err = pcall(quota.run, ctx)
        assert.falsy(ok)
        assert.match("QUOTA", err)
    end)

    it("fires budget_exceeded webhook on gateway block", function()
        _spend_read["gateway:gw1"] = 500000
        local quota = require("middleware.quota")
        local wh = { url = "http://hook.test/wh" }
        local ctx = make_ctx({ gateway_config = { budget_usd = 0.5, webhooks = wh } })
        pcall(quota.run, ctx)
        assert.equal(1, #_webhook_calls)
        assert.equal("gateway", _webhook_calls[1].data.scope)
    end)
end)
