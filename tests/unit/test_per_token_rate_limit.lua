-- tests/unit/test_per_token_rate_limit.lua
-- Tests for per-token rate limiting in middleware/rate_limit.lua
-- Run with: resty tests/runner.lua tests/unit/test_per_token_rate_limit.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls = {}
_G.ngx = {
    log     = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    WARN = 1, INFO = 2, ERR = 0,
    header  = {},
    status  = 200,
    exit    = function(code) error("ngx.exit("..code..")") end,
    req     = { read_body = function() end },
    ctx     = {},
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ─── module stubs ──────────────────────────────────────────────────────────
for _, n in ipairs({ "middleware.rate_limit", "state", "core.errors", "utils.json" }) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

-- Sliding-window stub: tracks call counts per key
local _counters = {}
local _blocked  = {}   -- keys that are "over limit"

package.preload["state"] = function()
    return {
        rate_limit_check = function(key, window_sec, limit)
            _counters[key] = (_counters[key] or 0) + 1
            if _blocked[key] then
                return false, _counters[key]
            end
            return true, _counters[key]
        end,
    }
end

local _errors = {}
package.preload["core.errors"] = function()
    return {
        send = function(code, msg)
            error("RATE_LIMITED:" .. tostring(msg))
        end,
    }
end

package.preload["utils.json"] = function()
    return require("cjson")
end

local rl = require("middleware.rate_limit")

-- ─── helpers ───────────────────────────────────────────────────────────────
local function reset()
    _counters = {}
    _blocked  = {}
    _log_calls = {}
    ngx.header = {}
end

local function make_ctx(opts)
    opts = opts or {}
    return {
        gateway_id     = opts.gateway_id    or "gw1",
        token_id       = opts.token_id,
        token_rate_limit = opts.token_rate_limit,
        gateway_config = opts.gateway_config or {},
        log_fields     = {},
    }
end

-- ─── test suite ────────────────────────────────────────────────────────────
describe("rate_limit: gateway-level limit", function()
    before_each(reset)

    it("passes when no rate_limit configured", function()
        local ctx = make_ctx()
        rl.run(ctx)   -- should not error
        assert.equal(0, #_log_calls)
    end)

    it("allows request within limit", function()
        local ctx = make_ctx({ gateway_config = { rate_limit = { requests = 10, window_sec = 60 } } })
        rl.run(ctx)
        assert.truthy(_counters["rl:gw1"])
        assert.equal("10", tostring(ngx.header["X-RateLimit-Limit"]))
    end)

    it("blocks and raises error when over limit", function()
        _blocked["rl:gw1"] = true
        local ctx = make_ctx({ gateway_config = { rate_limit = { requests = 5, window_sec = 60 } } })
        local ok, err = pcall(rl.run, ctx)
        assert.falsy(ok)
        assert.match("RATE_LIMITED", err)
        assert.equal("rate_limit", ctx.log_fields.blocked_by)
    end)
end)

describe("rate_limit: per-token limit (JSON string)", function()
    before_each(reset)

    it("checks token key when token_id and token_rate_limit present", function()
        local ctx = make_ctx({
            token_id         = "tok123",
            token_rate_limit = '{"requests":20,"window_sec":60}',
        })
        rl.run(ctx)
        assert.truthy(_counters["rl:token:tok123"])
    end)

    it("allows request within token limit", function()
        local ctx = make_ctx({
            token_id         = "tok2",
            token_rate_limit = '{"requests":5,"window_sec":30}',
        })
        rl.run(ctx)
        assert.equal("5", tostring(ngx.header["X-RateLimit-Limit"]))
    end)

    it("blocks and raises error when token over limit", function()
        _blocked["rl:token:tokX"] = true
        local ctx = make_ctx({
            token_id         = "tokX",
            token_rate_limit = '{"requests":1,"window_sec":60}',
        })
        local ok, err = pcall(rl.run, ctx)
        assert.falsy(ok)
        assert.match("RATE_LIMITED", err)
        assert.match("token", ctx.log_fields.block_reason)
    end)

    it("skips token check when token_id absent", function()
        local ctx = make_ctx({ token_rate_limit = '{"requests":5,"window_sec":60}' })
        rl.run(ctx)   -- no error, counter never touched
        assert.same({}, _counters)
    end)

    it("skips token check when token_rate_limit absent", function()
        local ctx = make_ctx({ token_id = "tok99" })
        rl.run(ctx)   -- no error
        assert.same({}, _counters)
    end)

    it("accepts token_rate_limit as a table (already decoded)", function()
        local ctx = make_ctx({
            token_id         = "tok3",
            token_rate_limit = { requests = 10, window_sec = 60 },
        })
        rl.run(ctx)
        assert.truthy(_counters["rl:token:tok3"])
    end)
end)

describe("rate_limit: both gateway and token limits checked", function()
    before_each(reset)

    it("checks both gateway and token keys when both configured", function()
        local ctx = make_ctx({
            gateway_config   = { rate_limit = { requests = 100, window_sec = 60 } },
            token_id         = "tokAB",
            token_rate_limit = '{"requests":10,"window_sec":60}',
        })
        rl.run(ctx)
        assert.truthy(_counters["rl:gw1"])
        assert.truthy(_counters["rl:token:tokAB"])
    end)

    it("gateway blocked before token is checked", function()
        _blocked["rl:gw1"] = true
        local ctx = make_ctx({
            gateway_config   = { rate_limit = { requests = 5, window_sec = 60 } },
            token_id         = "tokAB",
            token_rate_limit = '{"requests":10,"window_sec":60}',
        })
        local ok, err = pcall(rl.run, ctx)
        assert.falsy(ok)
        assert.match("RATE_LIMITED", err)
    end)
end)
