-- tests/unit/test_circuit_breaker.lua
-- Comprehensive tests for core/circuit_breaker.lua.
-- Run with: resty tests/runner.lua tests/unit/test_circuit_breaker.lua

local _now = 1700000000.0  -- controllable mock clock

_G.ngx = {
    now    = function() return _now end,
    log    = function() end,
    shared = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

for _, n in ipairs({"core.circuit_breaker", "core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

-- ---------------------------------------------------------------------------
-- Shared dict stub: in-memory dict with get/set/delete/incr
-- ---------------------------------------------------------------------------
local function make_dict()
    local store = {}
    return {
        get    = function(_, k)          return store[k] end,
        set    = function(_, k, v, _ttl) store[k] = v; return true end,
        delete = function(_, k)          store[k] = nil end,
        incr   = function(_, k, d, init, _exptime)
            if store[k] == nil then store[k] = (init or 0) end
            store[k] = store[k] + (d or 1)
            return store[k]
        end,
        -- Expose raw store for inspection in tests
        _store = store,
    }
end

local rl_dict  = make_dict()
local cfg_dict = make_dict()

package.preload["core.app_config"] = function()
    return {
        shared_dict = {
            rate_limit = "aig_ratelimit",
            config     = "aig_config",
        }
    }
end

_G.ngx.shared = { aig_ratelimit = rl_dict, aig_config = cfg_dict }

local cb = require("core.circuit_breaker")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local GW1 = "gw-111"
local GW2 = "gw-222"
local OAI = "openai"
local ANT = "anthropic"

local CFG = {   -- default config for most tests
    enabled           = true,
    failure_threshold = 3,
    window_sec        = 60,
    cooldown_ms       = 10000,   -- 10 s
}

local function reset()
    rl_dict  = make_dict()
    cfg_dict = make_dict()
    _G.ngx.shared.aig_ratelimit = rl_dict
    _G.ngx.shared.aig_config    = cfg_dict
    _now = 1700000000.0
end

-- Trip the breaker for a given gw/provider using the given status code
local function trip(gw, provider, cfg_arg, status)
    local c = cfg_arg or CFG
    for _ = 1, c.failure_threshold do
        cb.record_failure(gw, provider, c, status or 502)
    end
end

-- Advance clock by `sec` seconds
local function advance(sec) _now = _now + sec end

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — disabled / no-op", function()
    before_each(reset)

    it("check returns allow when cfg is nil", function()
        assert.equal("allow", cb.check(GW1, OAI, nil))
    end)

    it("check returns allow when cfg.enabled is false", function()
        assert.equal("allow", cb.check(GW1, OAI, { enabled = false }))
    end)

    it("record_failure is a no-op when cfg is nil", function()
        cb.record_failure(GW1, OAI, nil, 502)
        assert.equal("allow", cb.check(GW1, OAI, nil))
    end)

    it("record_failure is a no-op when cfg.enabled is false", function()
        local c = { enabled = false, failure_threshold = 1 }
        cb.record_failure(GW1, OAI, c, 502)
        assert.equal("allow", cb.check(GW1, OAI, c))
    end)

    it("record_success is a no-op when cfg is nil", function()
        cb.record_success(GW1, OAI, nil)  -- must not error
        assert.equal("allow", cb.check(GW1, OAI, nil))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — CLOSED state", function()
    before_each(reset)

    it("allows requests with zero failures", function()
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("allows requests when failures are below threshold", function()
        for _ = 1, CFG.failure_threshold - 1 do
            cb.record_failure(GW1, OAI, CFG, 502)
        end
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("allows requests with threshold=1 until the first failure fires", function()
        local c = { enabled = true, failure_threshold = 1, window_sec = 60, cooldown_ms = 5000 }
        assert.equal("allow", cb.check(GW1, OAI, c))
        cb.record_failure(GW1, OAI, c, 502)
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)

    it("record_success when closed is a no-op (no state stored)", function()
        cb.record_success(GW1, OAI, CFG)
        assert.is_nil(cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("uses default failure_threshold (5) when not specified", function()
        local c = { enabled = true }  -- no failure_threshold
        for _ = 1, 4 do cb.record_failure(GW1, OAI, c, 502) end
        assert.equal("allow", cb.check(GW1, OAI, c))
        cb.record_failure(GW1, OAI, c, 502)
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — CLOSED → OPEN transition", function()
    before_each(reset)

    it("opens after exactly failure_threshold failures", function()
        trip(GW1, OAI)
        assert.equal("deny", cb.check(GW1, OAI, CFG))
    end)

    it("state key is set to 'open' after opening", function()
        trip(GW1, OAI)
        assert.equal("open", cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)

    it("opened_at key is set to current time after opening", function()
        trip(GW1, OAI)
        local opened = tonumber(cfg_dict:get("cb:opened:" .. GW1 .. ":" .. OAI))
        assert.is_true(math.abs(opened - _now) < 1, "opened_at not near current time")
    end)

    it("extra failures past threshold do not corrupt state", function()
        trip(GW1, OAI)
        for _ = 1, 10 do cb.record_failure(GW1, OAI, CFG, 502) end
        assert.equal("deny",  cb.check(GW1, OAI, CFG))
        assert.equal("open",  cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)

    it("record_failure while open does not change opened_at timestamp", function()
        trip(GW1, OAI)
        local opened_at_1 = cfg_dict:get("cb:opened:" .. GW1 .. ":" .. OAI)
        advance(2)
        cb.record_failure(GW1, OAI, CFG, 503)  -- already open
        local opened_at_2 = cfg_dict:get("cb:opened:" .. GW1 .. ":" .. OAI)
        assert.equal(opened_at_1, opened_at_2)
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — OPEN state: deny while cooling", function()
    before_each(reset)

    it("denies immediately after opening (t=0)", function()
        trip(GW1, OAI)
        assert.equal("deny", cb.check(GW1, OAI, CFG))
    end)

    it("denies at t = cooldown - 1s (just before expiry)", function()
        trip(GW1, OAI)
        advance((CFG.cooldown_ms / 1000) - 1)
        assert.equal("deny", cb.check(GW1, OAI, CFG))
    end)

    it("denies consistently across multiple check calls", function()
        trip(GW1, OAI)
        advance(3)
        for _ = 1, 10 do
            assert.equal("deny", cb.check(GW1, OAI, CFG))
        end
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — OPEN → HALF_OPEN transition", function()
    before_each(reset)

    it("allows one request exactly at cooldown boundary", function()
        trip(GW1, OAI)
        advance(CFG.cooldown_ms / 1000)  -- exactly at boundary
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("transitions state to 'half_open' after cooldown", function()
        trip(GW1, OAI)
        advance((CFG.cooldown_ms / 1000) + 1)
        cb.check(GW1, OAI, CFG)
        assert.equal("half_open", cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)

    it("subsequent check calls while half_open also return allow", function()
        trip(GW1, OAI)
        advance((CFG.cooldown_ms / 1000) + 1)
        cb.check(GW1, OAI, CFG)  -- transitions to half_open
        -- All further checks should also allow (probe ongoing)
        for _ = 1, 5 do
            assert.equal("allow", cb.check(GW1, OAI, CFG))
        end
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — HALF_OPEN → CLOSED (probe success)", function()
    before_each(reset)

    local function open_and_half_open()
        trip(GW1, OAI)
        advance((CFG.cooldown_ms / 1000) + 1)
        cb.check(GW1, OAI, CFG)  -- → half_open
    end

    it("record_success from half_open closes the breaker", function()
        open_and_half_open()
        cb.record_success(GW1, OAI, CFG)
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("state key is removed after closing", function()
        open_and_half_open()
        cb.record_success(GW1, OAI, CFG)
        assert.is_nil(cfg_dict:get("cb:state:"  .. GW1 .. ":" .. OAI))
        assert.is_nil(cfg_dict:get("cb:opened:" .. GW1 .. ":" .. OAI))
    end)

    it("failure counter is reset after closing", function()
        open_and_half_open()
        cb.record_success(GW1, OAI, CFG)
        -- Counter key should be gone so threshold failures are needed again
        assert.is_nil(rl_dict:get("cb:fail:" .. GW1 .. ":" .. OAI))
    end)

    it("can open again from fresh closed state after a successful probe", function()
        open_and_half_open()
        cb.record_success(GW1, OAI, CFG)
        trip(GW1, OAI)
        assert.equal("deny", cb.check(GW1, OAI, CFG))
    end)

    it("record_success when already open (not half_open) also closes", function()
        trip(GW1, OAI)  -- open, not half_open
        cb.record_success(GW1, OAI, CFG)
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        assert.is_nil(cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — HALF_OPEN → OPEN (probe failure)", function()
    before_each(reset)

    local function open_and_half_open()
        trip(GW1, OAI)
        advance((CFG.cooldown_ms / 1000) + 1)
        cb.check(GW1, OAI, CFG)  -- → half_open
    end

    it("probe failure re-opens the breaker immediately", function()
        open_and_half_open()
        cb.record_failure(GW1, OAI, CFG, 502)
        assert.equal("deny", cb.check(GW1, OAI, CFG))
    end)

    it("re-opened breaker has a fresh opened_at timestamp", function()
        open_and_half_open()
        local t_reopen = _now + 5
        _now = t_reopen
        cb.record_failure(GW1, OAI, CFG, 502)
        local opened = tonumber(cfg_dict:get("cb:opened:" .. GW1 .. ":" .. OAI))
        assert.is_true(math.abs(opened - t_reopen) < 1)
    end)

    it("re-opened breaker requires full cooldown again before probing", function()
        open_and_half_open()
        advance(2)
        cb.record_failure(GW1, OAI, CFG, 502)  -- re-opened at _now

        advance((CFG.cooldown_ms / 1000) - 1)  -- not yet elapsed
        assert.equal("deny", cb.check(GW1, OAI, CFG))

        advance(2)  -- now elapsed
        assert.equal("allow", cb.check(GW1, OAI, CFG))
    end)

    it("full two-probe cycle: fail → reopen → pass → close", function()
        -- First probe fails → re-open
        open_and_half_open()
        cb.record_failure(GW1, OAI, CFG, 503)
        assert.equal("deny", cb.check(GW1, OAI, CFG))

        -- Second probe succeeds → close
        advance((CFG.cooldown_ms / 1000) + 1)
        cb.check(GW1, OAI, CFG)  -- → half_open again
        cb.record_success(GW1, OAI, CFG)
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        assert.is_nil(cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — isolation between providers and gateways", function()
    before_each(reset)

    it("two providers on same gateway are tracked independently", function()
        trip(GW1, OAI)
        assert.equal("deny",  cb.check(GW1, OAI, CFG))
        assert.equal("allow", cb.check(GW1, ANT, CFG))
    end)

    it("two gateways with same provider are tracked independently", function()
        trip(GW1, OAI)
        assert.equal("deny",  cb.check(GW1, OAI, CFG))
        assert.equal("allow", cb.check(GW2, OAI, CFG))
    end)

    it("closing one breaker does not affect the other", function()
        trip(GW1, OAI)
        trip(GW1, ANT)
        -- Close openai directly (record_success works from open state too)
        -- Do NOT advance time so ANT's cooldown is still active
        cb.record_success(GW1, OAI, CFG)
        -- openai closed, anthropic still open (cooldown not elapsed)
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        assert.equal("deny",  cb.check(GW1, ANT, CFG))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — failure_status_codes filtering", function()
    before_each(reset)

    it("default codes (no config key): 500 triggers counter", function()
        local c = { enabled = true, failure_threshold = 3, window_sec = 60, cooldown_ms = 5000 }
        -- 500 is in default set [500, 502, 503, 504]
        for _ = 1, 3 do cb.record_failure(GW1, OAI, c, 500) end
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)

    it("default codes: 502, 503, 504 all trigger", function()
        for _, code in ipairs({502, 503, 504}) do
            reset()
            local c = { enabled = true, failure_threshold = 1, window_sec = 60, cooldown_ms = 5000 }
            cb.record_failure(GW1, OAI, c, code)
            assert.equal("deny", cb.check(GW1, OAI, c),
                "code " .. code .. " should trigger but didn't")
        end
    end)

    it("custom failure_status_codes: excluded code does not increment counter", function()
        local c = {
            enabled = true, failure_threshold = 3, window_sec = 60, cooldown_ms = 5000,
            failure_status_codes = { 502, 503, 504 },  -- 500 excluded
        }
        for _ = 1, 10 do cb.record_failure(GW1, OAI, c, 500) end
        assert.equal("allow", cb.check(GW1, OAI, c))
    end)

    it("custom failure_status_codes: included code increments counter", function()
        local c = {
            enabled = true, failure_threshold = 3, window_sec = 60, cooldown_ms = 5000,
            failure_status_codes = { 502, 503, 504 },
        }
        for _ = 1, 3 do cb.record_failure(GW1, OAI, c, 503) end
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)

    it("mixed: only counted codes accumulate toward threshold", function()
        local c = {
            enabled = true, failure_threshold = 3, window_sec = 60, cooldown_ms = 5000,
            failure_status_codes = { 503 },
        }
        -- 5× excluded 500 + 2× included 503 = 2 counted; threshold=3 → still allow
        for _ = 1, 5 do cb.record_failure(GW1, OAI, c, 500) end
        for _ = 1, 2 do cb.record_failure(GW1, OAI, c, 503) end
        assert.equal("allow", cb.check(GW1, OAI, c))
        -- One more 503 → 3 counted → open
        cb.record_failure(GW1, OAI, c, 503)
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)

    it("nil status (connection error) always counts regardless of failure_status_codes", function()
        local c = {
            enabled = true, failure_threshold = 3, window_sec = 60, cooldown_ms = 5000,
            failure_status_codes = { 999 },  -- a code that never appears naturally
        }
        for _ = 1, 3 do cb.record_failure(GW1, OAI, c, nil) end
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)

    it("nil status counts even with empty failure_status_codes list", function()
        local c = {
            enabled = true, failure_threshold = 2, window_sec = 60, cooldown_ms = 5000,
            failure_status_codes = {},  -- empty — nothing HTTP triggers, but nil still should
        }
        for _ = 1, 2 do cb.record_failure(GW1, OAI, c, nil) end
        assert.equal("deny", cb.check(GW1, OAI, c))
    end)
end)

-- ---------------------------------------------------------------------------

describe("core.circuit_breaker — complete lifecycle", function()
    before_each(reset)

    it("full happy path: closed → open → half_open → closed", function()
        -- 1. Closed: below threshold
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        for _ = 1, CFG.failure_threshold - 1 do
            cb.record_failure(GW1, OAI, CFG, 502)
        end
        assert.equal("allow", cb.check(GW1, OAI, CFG))

        -- 2. Open: threshold reached
        cb.record_failure(GW1, OAI, CFG, 502)
        assert.equal("deny", cb.check(GW1, OAI, CFG))

        -- 3. Still open: cooldown not elapsed
        advance(5)
        assert.equal("deny", cb.check(GW1, OAI, CFG))

        -- 4. Half-open: cooldown elapsed
        advance(6)  -- total 11s > 10s cooldown
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        assert.equal("half_open", cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))

        -- 5. Probe succeeds → closed
        cb.record_success(GW1, OAI, CFG)
        assert.equal("allow", cb.check(GW1, OAI, CFG))
        assert.is_nil(cfg_dict:get("cb:state:" .. GW1 .. ":" .. OAI))
    end)

    it("three full open/close cycles work correctly", function()
        for cycle = 1, 3 do
            trip(GW1, OAI)
            assert.equal("deny", cb.check(GW1, OAI, CFG),
                "cycle " .. cycle .. ": should be denied after trip")

            advance((CFG.cooldown_ms / 1000) + 1)
            cb.check(GW1, OAI, CFG)  -- → half_open
            cb.record_success(GW1, OAI, CFG)
            assert.equal("allow", cb.check(GW1, OAI, CFG),
                "cycle " .. cycle .. ": should allow after recovery")
        end
    end)
end)
