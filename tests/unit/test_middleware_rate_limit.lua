-- tests/unit/test_middleware_rate_limit.lua — src/middleware/rate_limit.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_rate_limit.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local _log_buf = {}
local _headers = {}
local _exited  = nil

_G.ngx = {
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function() end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = {},
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
}

-- Rate limit counter: key → count
local _counters = {}

for _, n in ipairs({"middleware.rate_limit","state","core.errors","utils.json","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end

package.preload["state"] = function()
    return {
        rate_limit_check = function(key, window_sec, limit)
            _counters[key] = (_counters[key] or 0) + 1
            local count = _counters[key]
            return count <= limit, count
        end,
    }
end

package.preload["core.errors"] = function()
    return {
        send = function(code, detail) error(code, 0) end,
        codes = {},
    }
end

package.preload["utils.json"] = function()
    local cjson = require("cjson.safe")
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

local rl = require("middleware.rate_limit")

local function reset()
    _log_buf  = {}
    _headers  = {}
    _exited   = nil
    _counters = {}
    _G.ngx.status = 200
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end })
    _G.ngx.ctx    = {}
end

local function make_ctx(gw_rl, token_id, token_rl)
    return {
        gateway_id     = "gw-001",
        gateway_config = { rate_limit = gw_rl },
        token_id       = token_id,
        token_rate_limit = token_rl,
        log_fields     = {},
    }
end

-- ============================================================================
-- Gateway-level rate limit
-- ============================================================================

describe("middleware.rate_limit: gateway-level", function()

    it("passes when gateway has no rate_limit config", function()
        reset()
        local ctx = make_ctx(nil)
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok, "no rate limit config must not block")
    end)

    it("passes when request count is under the limit", function()
        reset()
        local ctx = make_ctx({ requests = 10, window_sec = 60 })
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok)
    end)

    it("blocks when limit is exceeded (counter > limit)", function()
        reset()
        -- Pre-seed the counter to be at the limit
        _counters["rl:gw-001"] = 5
        local ctx = make_ctx({ requests = 5, window_sec = 60 })
        local ok, err = pcall(rl.run, ctx)
        assert.is_false(ok)
        assert.equal("RATE_LIMITED", tostring(err))
    end)

    it("sets X-RateLimit-Limit header when rate limit is configured", function()
        reset()
        local ctx = make_ctx({ requests = 100, window_sec = 60 })
        pcall(rl.run, ctx)
        assert.equal(100, _headers["X-RateLimit-Limit"])
    end)

    it("sets X-RateLimit-Remaining to limit - count when under limit", function()
        reset()
        local ctx = make_ctx({ requests = 100, window_sec = 60 })
        pcall(rl.run, ctx)
        assert.not_nil(_headers["X-RateLimit-Remaining"])
        assert.is_true(_headers["X-RateLimit-Remaining"] >= 0)
    end)

    it("sets Retry-After and X-RateLimit-Remaining=0 when blocked", function()
        reset()
        _counters["rl:gw-001"] = 10
        local ctx = make_ctx({ requests = 10, window_sec = 30 })
        pcall(rl.run, ctx)
        assert.equal(0,  _headers["X-RateLimit-Remaining"])
        assert.equal(30, _headers["Retry-After"])
    end)

    it("sets log_fields.blocked_by = 'rate_limit' when blocked", function()
        reset()
        _counters["rl:gw-001"] = 5
        local ctx = make_ctx({ requests = 5, window_sec = 60 })
        pcall(rl.run, ctx)
        assert.equal("rate_limit", ctx.log_fields.blocked_by)
    end)

end)

-- ============================================================================
-- Per-token rate limit
-- ============================================================================

describe("middleware.rate_limit: per-token", function()

    it("skips per-token check when token has no rate_limit", function()
        reset()
        local ctx = make_ctx(nil, "tok-1", nil)
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok)
    end)

    it("passes when token request count is under the limit", function()
        reset()
        local ctx = make_ctx(nil, "tok-2", { requests = 20, window_sec = 60 })
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok)
    end)

    it("blocks on per-token limit even when gateway limit is not reached", function()
        reset()
        _counters["rl:token:tok-3"] = 5
        local ctx = make_ctx({ requests = 1000, window_sec = 60 },
                             "tok-3", { requests = 5, window_sec = 60 })
        local ok, err = pcall(rl.run, ctx)
        assert.is_false(ok)
        assert.equal("RATE_LIMITED", tostring(err))
    end)

    it("parses per-token rate_limit from JSON string", function()
        reset()
        local ctx = make_ctx(nil, "tok-4",
            '{"requests":50,"window_sec":60}')  -- JSON string, not table
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok, "JSON string rate_limit must be parsed and work")
    end)

    it("parses per-token rate_limit from table", function()
        reset()
        local ctx = make_ctx(nil, "tok-5",
            { requests = 50, window_sec = 60 })  -- already a table
        local ok = pcall(rl.run, ctx)
        assert.is_true(ok, "table rate_limit must work")
    end)

end)
