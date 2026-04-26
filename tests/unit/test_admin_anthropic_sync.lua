-- tests/unit/test_admin_anthropic_sync.lua — pure function tests for
-- admin/anthropic_usage_sync.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_anthropic_sync.lua
--
-- We cannot import local Lua functions directly, so we extract them via
-- debug.getupvalue traversal:
--   M.sync_recent  → upvalue 1 = rfc3339, upvalue 2 = utc_day,
--                    upvalue 4 = sync_tenant
--   sync_tenant    → upvalue 3 = parse_bucket
--   parse_bucket   → upvalue 1 = date_str, upvalue 2 = compute_cost
--
-- Coverage:
--   1. rfc3339: deterministic RFC-3339 formatting
--   2. date_str: YYYY-MM-DD formatting
--   3. compute_cost: standard/batch/priority tiers, cache tokens, unknown model
--   4. parse_bucket: field extraction, cache_creation nesting, web_search,
--      snapshot_date from _start_time, graceful nil handling

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _prev_e64 = _G.ngx and _G.ngx.encode_base64
local _prev_d64 = _G.ngx and _G.ngx.decode_base64

_G.ngx = {
    log           = function() end,
    time          = function() return 1700000000 end,
    now           = function() return 1700000000.0 end,
    escape_uri    = function(s) return s end,
    encode_base64 = _prev_e64,
    decode_base64 = _prev_d64,
    ERR        = 0, WARN = 1, INFO = 2,
}

-- ---------------------------------------------------------------------------
-- Storage stub: controls get_model_pricing return value per test
-- ---------------------------------------------------------------------------
local _pricing_table = {}  -- { ["anthropic/model"] = { input_per_1k, output_per_1k, ... } }

local storage_stub = {
    get_model_pricing = function(provider, model)
        return _pricing_table[provider .. "/" .. model], nil
    end,
    upsert_anthropic_usage = function() return nil end,
    list_tenants_with_anthropic_admin_key = function() return {} end,
}

for _, n in ipairs({
    "admin.anthropic_usage_sync", "storage", "auth.byok", "core.app_config",
}) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

package.loaded["storage"]          = storage_stub
package.preload["auth.byok"]       = function() return {} end
package.preload["core.app_config"] = function() return {} end
package.preload["cjson.safe"]      = function() return cjson end

local M = require("admin.anthropic_usage_sync")

-- ---------------------------------------------------------------------------
-- Extract local functions via debug.getupvalue
-- ---------------------------------------------------------------------------
local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then break end
        if n == name then return v end
        i = i + 1
    end
    error("upvalue '" .. name .. "' not found in function", 2)
end

local rfc3339     = upvalue(M.sync_recent,                     "rfc3339")
local sync_tenant = upvalue(M.sync_recent,                     "sync_tenant")
local parse_bucket= upvalue(sync_tenant,                       "parse_bucket")
local date_str    = upvalue(parse_bucket,                      "date_str")
local compute_cost= upvalue(parse_bucket,                      "compute_cost")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function reset_pricing()
    _pricing_table = {}
end

local function set_price(model, inp, out, cr, cw5m, cw1h)
    _pricing_table["anthropic/" .. model] = {
        input_per_1k          = inp   or 0,
        output_per_1k         = out   or 0,
        cache_read_per_1k     = cr    or 0,
        cache_write_per_1k    = cw5m  or 0,
        cache_write_1h_per_1k = cw1h,  -- nil = default to cw5m * 1.6
    }
end

-- ===========================================================================
-- rfc3339
-- ===========================================================================

describe("anthropic_sync: rfc3339", function()
    it("formats a known Unix timestamp to RFC-3339 UTC string", function()
        -- 1700000000 = 2023-11-14T22:13:20Z
        local s = rfc3339(1700000000)
        assert.equal("2023-11-14T22:13:20Z", s)
    end)

    it("output ends in Z (UTC suffix)", function()
        local s = rfc3339(0)
        assert.match("Z$", s)
    end)

    it("output matches YYYY-MM-DDTHH:MM:SSZ format", function()
        local s = rfc3339(1700000000)
        assert.match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$", s)
    end)
end)

-- ===========================================================================
-- date_str
-- ===========================================================================

describe("anthropic_sync: date_str", function()
    it("formats a known Unix timestamp to YYYY-MM-DD", function()
        -- 1700000000 is 2023-11-14
        local d = date_str(1700000000)
        assert.equal("2023-11-14", d)
    end)

    it("output is exactly YYYY-MM-DD format (10 chars)", function()
        local d = date_str(1700000000)
        assert.equal(10, #d)
        assert.match("^%d%d%d%d%-%d%d%-%d%d$", d)
    end)
end)

-- ===========================================================================
-- compute_cost
-- ===========================================================================

describe("anthropic_sync: compute_cost standard tier", function()
    -- Prices are dollars per 1000 tokens. Formula: tokens * price_per_1k / 1000.
    -- Example: 1000 tokens at price_per_1k=1.0 → cost = 1000 * 1.0 / 1000 = 1.0
    before_each(function() reset_pricing() end)

    it("input tokens priced at input_per_1k / 1000", function()
        set_price("m", 2.0, 0.0)
        -- 500 input tokens × $2.0/1k / 1000 = 500*2.0/1000 = 1.0
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 500,
            output_tokens         = 0,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("output tokens priced at output_per_1k / 1000", function()
        set_price("m", 0.0, 4.0)
        -- 250 output tokens × $4.0/1k / 1000 = 250*4.0/1000 = 1.0
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 250,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("cache read tokens priced at cache_read_per_1k / 1000", function()
        set_price("m", 0.0, 0.0, 2.0)
        -- 500 cache_read_tokens × $2.0/1k / 1000 = 500*2.0/1000 = 1.0
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 0,
            cache_read_tokens     = 500,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("cache write 5m tokens priced at cache_write_per_1k / 1000", function()
        set_price("m", 0.0, 0.0, 0.0, 4.0)
        -- 250 cache_write_5m × $4.0/1k / 1000 = 250*4.0/1000 = 1.0
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 0,
            cache_write_5m        = 250,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("cache write 1h tokens use explicit cache_write_1h_per_1k when set", function()
        set_price("m", 0.0, 0.0, 0.0, 1.0, 4.0)
        -- 250 cache_write_1h × $4.0/1k / 1000 = 250*4.0/1000 = 1.0
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 0,
            cache_write_1h        = 250,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("cache write 1h falls back to cw5m * 1.6 when 1h price not set", function()
        set_price("m", 0.0, 0.0, 0.0, 1.0, nil)
        -- cw1h defaults to 1.0 * 1.6 = 1.6
        -- 1000 cache_write_1h × $1.6/1k / 1000 = 1000*1.6/1000 = 1.6
        local cost = compute_cost("m", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 0,
            cache_write_1h        = 1000,
        })
        assert.near(1.6, cost, 0.000001)
    end)

    it("all zero tokens → cost is 0", function()
        set_price("claude-3-5-haiku-20241022", 0.8, 4.0)
        local cost = compute_cost("claude-3-5-haiku-20241022", "standard", {
            uncached_input_tokens = 0,
            output_tokens         = 0,
        })
        assert.equal(0, cost)
    end)

    it("unknown model (no pricing entry) → returns 0", function()
        -- No price set for this model
        local cost = compute_cost("unknown-model-xyz", "standard", {
            uncached_input_tokens = 1000,
            output_tokens         = 500,
        })
        assert.equal(0, cost)
    end)
end)

describe("anthropic_sync: compute_cost tier variants", function()
    before_each(function() reset_pricing() end)

    it("batch tier applies 50% discount", function()
        set_price("m", 2.0, 0.0)
        -- Standard: 1000 tokens × $2.0/1k / 1000 = 2.0
        -- Batch: 2.0 × 0.5 = 1.0
        local cost = compute_cost("m", "batch", {
            uncached_input_tokens = 1000,
            output_tokens         = 0,
        })
        assert.near(1.0, cost, 0.000001)
    end)

    it("priority tier always returns 0 (different billing model)", function()
        set_price("m", 2.0, 4.0)
        local cost = compute_cost("m", "priority", {
            uncached_input_tokens = 100000,
            output_tokens         = 50000,
        })
        assert.equal(0, cost)
    end)

    it("priority_on_demand tier also returns 0", function()
        set_price("m", 2.0, 4.0)
        local cost = compute_cost("m", "priority_on_demand", {
            uncached_input_tokens = 1000,
            output_tokens         = 500,
        })
        assert.equal(0, cost)
    end)
end)

-- ===========================================================================
-- parse_bucket
-- ===========================================================================

describe("anthropic_sync: parse_bucket basic fields", function()
    before_each(function()
        reset_pricing()
        set_price("claude-3-5-haiku-20241022", 0.8, 4.0)
    end)

    it("returns tenant_id, snapshot_date, model, service_tier", function()
        local result = {
            model        = "claude-3-5-haiku-20241022",
            service_tier = "standard",
            _start_time  = 1700000000,  -- 2023-11-14
            uncached_input_tokens = 100,
            output_tokens         = 50,
        }
        local row = parse_bucket(result, "tn-test", "byok")
        assert.equal("tn-test",                     row.tenant_id)
        assert.equal("2023-11-14",                  row.snapshot_date)
        assert.equal("claude-3-5-haiku-20241022",   row.model)
        assert.equal("standard",                    row.service_tier)
        assert.equal("byok",                        row.source)
    end)

    it("basic token fields mapped correctly", function()
        local result = {
            model                 = "claude-3-5-haiku-20241022",
            service_tier          = "standard",
            _start_time           = 1700000000,
            uncached_input_tokens = 200,
            output_tokens         = 80,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(200, row.uncached_input_tokens)
        assert.equal(80,  row.output_tokens)
    end)

    it("cost_usd formatted to 8 decimal places as string", function()
        local result = {
            model                 = "claude-3-5-haiku-20241022",
            service_tier          = "standard",
            _start_time           = 1700000000,
            uncached_input_tokens = 1000,
            output_tokens         = 0,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.is_string(row.cost_usd, "cost_usd must be a string")
        assert.match("^%d+%.%d%d%d%d%d%d%d%d$", row.cost_usd)
    end)
end)

describe("anthropic_sync: parse_bucket cache_creation nesting", function()
    before_each(function() reset_pricing() end)

    it("cache_creation.ephemeral_5m_input_tokens → cache_write_5m_tokens", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
            cache_creation = { ephemeral_5m_input_tokens = 500 },
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(500, row.cache_write_5m_tokens)
    end)

    it("cache_creation.ephemeral_1h_input_tokens → cache_write_1h_tokens", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
            cache_creation = { ephemeral_1h_input_tokens = 300 },
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(300, row.cache_write_1h_tokens)
    end)

    it("absent cache_creation defaults both fields to 0", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(0, row.cache_write_5m_tokens)
        assert.equal(0, row.cache_write_1h_tokens)
    end)
end)

describe("anthropic_sync: parse_bucket web_search and edge cases", function()
    before_each(function() reset_pricing() end)

    it("server_tool_use.web_search_requests → web_search_requests field", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
            server_tool_use = { web_search_requests = 7 },
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(7, row.web_search_requests)
    end)

    it("absent server_tool_use → web_search_requests = 0", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(0, row.web_search_requests)
    end)

    it("cache_read_input_tokens mapped to cache_read_tokens", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 1700000000,
            uncached_input_tokens = 0, output_tokens = 0,
            cache_read_input_tokens = 150,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.equal(150, row.cache_read_tokens)
    end)

    it("_start_time=0 falls back gracefully without crash", function()
        local result = {
            model        = "m", service_tier = "standard", _start_time = 0,
            uncached_input_tokens = 0, output_tokens = 0,
        }
        local row = parse_bucket(result, "tn-x", "byok")
        assert.is_string(row.snapshot_date)
        assert.equal(10, #row.snapshot_date)
    end)
end)
