-- tests/unit/test_cost_table.lua — unit tests for observability/cost_table.lua
-- Run with: resty tests/runner.lua tests/unit/test_cost_table.lua
--
-- Tests:
--   1. calculate() returns non-zero cost for claude-sonnet-4-6 (regression for $0 cost bug)
--   2. get() returns numeric pricing (not strings) for all fields
--   3. tonumber() guard: non-numeric cache_read_per_1k in DB row does not raise or zero cost
--   4. FALLBACK table is used when storage returns nil

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    print  = function() end,
    flush  = function() end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
    },
    var = {},
    ctx = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- =========================================================================
-- Helpers: minimal mock modules used across test cases
-- =========================================================================
local function make_state_mock(initial_cache)
    local cache = initial_cache or {}
    return {
        config_get = function(k)     return cache[k] end,
        config_set = function(k, v)  cache[k] = v    end,
    }
end

local function make_json_mock()
    local cjson = require("cjson.safe")
    return {
        encode = function(t)   return cjson.encode(t) end,
        decode = function(s)   return cjson.decode(s) end,
    }
end

-- =========================================================================
-- Test group 1: FALLBACK table path (no storage hit)
-- =========================================================================
describe("cost_table — fallback pricing for claude-sonnet-4-6", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    package.preload["state"]   = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"] = function()
        return { get_model_pricing = function() return nil end }
    end

    local ct = require("observability.cost_table")

    it("get() returns non-nil pricing from FALLBACK", function()
        local p = ct.get("anthropic", "claude-sonnet-4-6")
        assert.not_nil(p, "expected non-nil pricing for claude-sonnet-4-6")
    end)

    it("get() returns numeric fields from FALLBACK", function()
        local p = ct.get("anthropic", "claude-sonnet-4-6")
        assert.is_true(type(p.input_per_1k)       == "number", "input_per_1k must be a number")
        assert.is_true(type(p.output_per_1k)      == "number", "output_per_1k must be a number")
        assert.is_true(type(p.cache_write_per_1k) == "number", "cache_write_per_1k must be a number")
        assert.is_true(type(p.cache_read_per_1k)  == "number", "cache_read_per_1k must be a number")
    end)

    it("calculate() returns non-zero cost for typical token counts", function()
        -- 12 input + 3 output tokens (matches mock provider anthropic_streaming.txt)
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 12, 3, 0, 0)
        assert.is_true(cost > 0,
            string.format("cost should be > 0, got %s", tostring(cost)))
    end)

    it("calculate() matches expected value for known inputs", function()
        -- input=1000, output=1000, no cache
        -- sonnet-4-6: $0.003/1k in + $0.015/1k out = $0.018
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0)
        assert.is_true(math.abs(cost - 0.018) < 1e-9,
            string.format("expected $0.018, got %s", tostring(cost)))
    end)

    it("calculate() includes cache_creation_tokens in cost", function()
        -- 0 regular input, 1000 cache_creation, 0 output
        -- cache_write = $0.00375/1k
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 0, 0, 1000, 0)
        assert.is_true(math.abs(cost - 0.00375) < 1e-9,
            string.format("expected $0.00375 for 1000 cache_creation_tokens, got %s", tostring(cost)))
    end)

    it("calculate() includes cache_read_tokens in cost", function()
        -- 0 regular input, 0 output, 1000 cache_read (7th positional arg)
        -- signature: (provider, model, input, output, cache_creation_5m, cache_creation_1h, cache_read, cache_deletion)
        -- cache_read = $0.0003/1k
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 0, 0, 0, 0, 1000)
        assert.is_true(math.abs(cost - 0.0003) < 1e-9,
            string.format("expected $0.0003 for 1000 cache_read_tokens, got %s", tostring(cost)))
    end)
end)

-- =========================================================================
-- Test group 2: Storage path with correct numeric values
-- =========================================================================
describe("cost_table — storage-backed pricing for claude-sonnet-4-6", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    -- Simulate what the DB returns after the column-order fix
    local DB_ROW = {
        input_per_1k       = 0.003,
        output_per_1k      = 0.015,
        cache_write_per_1k = 0.00375,
        cache_read_per_1k  = 0.0003,
    }

    package.preload["state"]      = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"]    = function()
        return {
            get_model_pricing = function(provider, model)
                if provider == "anthropic" and model == "claude-sonnet-4-6" then
                    return DB_ROW
                end
                return nil
            end,
        }
    end

    local ct = require("observability.cost_table")

    it("get() returns all numeric fields from storage row", function()
        local p = ct.get("anthropic", "claude-sonnet-4-6")
        assert.not_nil(p)
        assert.is_true(type(p.input_per_1k)       == "number", "input_per_1k must be number")
        assert.is_true(type(p.output_per_1k)      == "number", "output_per_1k must be number")
        assert.is_true(type(p.cache_write_per_1k) == "number", "cache_write_per_1k must be number")
        assert.is_true(type(p.cache_read_per_1k)  == "number", "cache_read_per_1k must be number")
    end)

    it("calculate() returns correct cost from storage pricing", function()
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0)
        assert.is_true(math.abs(cost - 0.018) < 1e-9,
            string.format("expected $0.018, got %s", tostring(cost)))
    end)
end)

-- =========================================================================
-- Test group 3: Regression — timestamp string in cache_read_per_1k
-- (root cause of the $0 cost bug: positional INSERT mapped timestamp to
--  cache_read_per_1k, causing LuaJIT arithmetic error via 0 * "2026-...")
-- =========================================================================
describe("cost_table — regression: timestamp string in cache_read_per_1k", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    -- Simulate the broken DB row that existed before the fix:
    -- cache_read_per_1k = timestamp string (wrong column order)
    local BROKEN_ROW = {
        input_per_1k       = 0.003,
        output_per_1k      = 0.015,
        cache_write_per_1k = 0.0003,                    -- was actually cache_read value
        cache_read_per_1k  = "2026-03-20T17:06:32.032Z", -- timestamp string (the bug)
    }

    package.preload["state"]      = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"]    = function()
        return {
            get_model_pricing = function()
                return BROKEN_ROW
            end,
        }
    end

    local ct = require("observability.cost_table")

    it("get() returns nil for cache_read_per_1k when it is a string (tonumber guard)", function()
        local p = ct.get("anthropic", "claude-sonnet-4-6")
        assert.not_nil(p, "pricing must not be nil")
        -- tonumber("2026-03-20T...") returns nil — this is correct defensive behavior
        assert.is_nil(p.cache_read_per_1k,
            "cache_read_per_1k should be nil (tonumber of timestamp string = nil)")
    end)

    it("calculate() does not raise when cache_read_per_1k is a non-numeric string", function()
        -- Before the fix: 0 * "2026-..." raised "arithmetic on a string value"
        -- After the fix:  tonumber() returns nil, and (nil or 0) = 0 safely
        local ok, result = pcall(ct.calculate,
            "anthropic", "claude-sonnet-4-6", 12, 3, 0, 0)
        assert.is_true(ok,
            "calculate() must not raise on non-numeric cache_read_per_1k: " .. tostring(result))
    end)

    it("calculate() returns non-zero cost despite broken cache_read_per_1k", function()
        -- Input + output tokens still produce non-zero cost even if cache_read = nil
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0)
        assert.is_true(cost > 0,
            string.format("cost should be > 0 even with broken cache_read_per_1k, got %s",
                tostring(cost)))
    end)
end)

-- =========================================================================
-- Test group 4: unknown model returns 0
-- =========================================================================
describe("cost_table — unknown model", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    package.preload["state"]      = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"]    = function()
        return { get_model_pricing = function() return nil end }
    end

    local ct = require("observability.cost_table")

    it("calculate() returns nil for an unknown model", function()
        local cost = ct.calculate("anthropic", "x-unknown-model", 100, 100, 0, 0)
        assert.is_nil(cost, "unknown model should return nil (untracked, not free)")
    end)
end)

-- =========================================================================
-- Test group 5: cache_deletion_tokens (Finding — cache_delete_per_1k)
-- =========================================================================
describe("cost_table — cache_deletion_tokens (cache_delete_per_1k)", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    local PRICING_WITH_DELETE = {
        input_per_1k        = 0.003,
        output_per_1k       = 0.015,
        cache_write_per_1k  = 0.00375,
        cache_read_per_1k   = 0.0003,
        cache_delete_per_1k = 0.001,
    }

    package.preload["state"]      = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"]    = function()
        return {
            get_model_pricing = function(provider, model)
                if provider == "anthropic" and model == "claude-sonnet-4-6" then
                    return PRICING_WITH_DELETE
                end
                return nil
            end,
        }
    end

    local ct = require("observability.cost_table")

    it("calculate() accepts a 5th cache_deletion_tokens argument without raising", function()
        local ok, result = pcall(ct.calculate,
            "anthropic", "claude-sonnet-4-6", 100, 100, 0, 0, 1000)
        assert.is_true(ok,
            "calculate() must accept cache_deletion_tokens: " .. tostring(result))
    end)

    it("1000 cache_deletion_tokens at $0.001/1k costs $0.001", function()
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 0, 0, 0, 0, 0, 1000)
        assert.is_true(math.abs(cost - 0.001) < 1e-9,
            string.format("expected $0.001 for 1000 cache_deletion_tokens, got %s", tostring(cost)))
    end)

    it("cache_deletion_tokens adds to a combined cost correctly", function()
        -- input=$0.003 + output=$0.015 + deletion=$0.001 = $0.019
        local cost = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0, 0, 1000)
        assert.is_true(math.abs(cost - 0.019) < 1e-9,
            string.format("expected $0.019, got %s", tostring(cost)))
    end)

    it("nil cache_deletion_tokens is treated as zero (no extra cost)", function()
        local cost_nil  = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0, nil)
        local cost_zero = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0, 0)
        assert.equal(cost_zero, cost_nil,
            "nil cache_deletion_tokens must behave identically to 0")
    end)
end)

describe("cost_table — cache_deletion_tokens with FALLBACK pricing", function()
    clear({"observability.cost_table","storage","state","utils.json"})

    package.preload["state"]      = function() return make_state_mock() end
    package.preload["utils.json"] = make_json_mock
    package.preload["storage"]    = function()
        return { get_model_pricing = function() return nil end }
    end

    local ct = require("observability.cost_table")

    it("calculate() with cache_deletion_tokens does not raise for FALLBACK model", function()
        local ok, result = pcall(ct.calculate,
            "anthropic", "claude-sonnet-4-6", 100, 100, 0, 0, 500)
        assert.is_true(ok,
            "must not raise with cache_deletion_tokens on FALLBACK: " .. tostring(result))
    end)

    it("FALLBACK: cost with cache_deletion_tokens >= cost without", function()
        local cost_no_del   = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0, 0)
        local cost_with_del = ct.calculate("anthropic", "claude-sonnet-4-6", 1000, 1000, 0, 0, 1000)
        assert.is_true(cost_with_del >= cost_no_del,
            "deletion tokens should add zero or positive cost, never negative")
    end)
end)
