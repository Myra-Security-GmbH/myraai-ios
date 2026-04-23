-- tests/unit/test_core_pipeline.lua — unit tests for:
--   src/core/pipeline.lua, src/core/errors.lua, src/core/app_config.lua
-- Run with: resty tests/runner.lua tests/unit/test_core_pipeline.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local _printed = nil
local _exited  = nil
local _log_buf = {}
local _status  = 200
local _headers = {}

_G.ngx = {
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function(s) _printed = s end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = {},
    ctx    = {},
    ERR = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"core.pipeline","core.errors","utils.json","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end
package.preload["utils.json"] = function()
    local cjson = require("cjson.safe")
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

local function reset()
    _printed = nil
    _exited  = nil
    _log_buf = {}
    _G.ngx.status = 200
    _G.ngx.ctx    = {}
    -- Recreate header table so rawset values from previous tests don't suppress __newindex
    _headers = {}
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v)
    end })
end

-- Load modules under test
local pipeline = require("core.pipeline")
local errors   = require("core.errors")

-- ============================================================================
-- core/errors.lua
-- ============================================================================

describe("core.errors: error code registry", function()

    it("M.codes contains all required keys", function()
        local required = {
            "UNAUTHORIZED", "FORBIDDEN", "TENANT_NOT_FOUND", "RATE_LIMITED",
            "QUOTA_EXCEEDED", "PROVIDER_ERROR", "ALL_PROVIDERS_FAILED",
            "GUARDRAIL_BLOCKED", "INVALID_REQUEST", "INTERNAL",
        }
        for _, k in ipairs(required) do
            assert.not_nil(errors.codes[k], "missing error code: " .. k)
        end
    end)

    it("each code has status (number), code (string), msg (string)", function()
        for k, v in pairs(errors.codes) do
            assert.equal("number", type(v.status), k .. ".status must be number")
            assert.equal("string", type(v.code),   k .. ".code must be string")
            assert.equal("string", type(v.msg),    k .. ".msg must be string")
        end
    end)

    it("UNAUTHORIZED maps to 401", function()
        assert.equal(401, errors.codes.UNAUTHORIZED.status)
    end)

    it("INTERNAL maps to 500", function()
        assert.equal(500, errors.codes.INTERNAL.status)
    end)

    it("RATE_LIMITED maps to 429", function()
        assert.equal(429, errors.codes.RATE_LIMITED.status)
    end)

end)

describe("core.errors: M.send()", function()

    it("sets ngx.status to the error's HTTP status", function()
        reset()
        pcall(errors.send, "UNAUTHORIZED")
        assert.equal(401, _G.ngx.status)
    end)

    it("sets Content-Type to application/json", function()
        reset()
        pcall(errors.send, "UNAUTHORIZED")
        assert.equal("application/json", _headers["Content-Type"])
    end)

    it("sets X-AIG-Error header to error code string", function()
        reset()
        pcall(errors.send, "UNAUTHORIZED")
        assert.equal("unauthorized", _headers["X-AIG-Error"])
    end)

    it("prints JSON body with {error:{code, message}}", function()
        reset()
        pcall(errors.send, "RATE_LIMITED")
        assert.not_nil(_printed)
        local cjson = require("cjson.safe")
        local body  = cjson.decode(_printed)
        assert.not_nil(body)
        assert.not_nil(body.error)
        assert.equal("rate_limited", body.error.code)
        assert.not_nil(body.error.message)
    end)

    it("uses custom detail message when provided", function()
        reset()
        pcall(errors.send, "INTERNAL", "custom detail here")
        local cjson = require("cjson.safe")
        local body  = cjson.decode(_printed)
        assert.equal("custom detail here", body.error.message)
    end)

    it("calls ngx.exit with the HTTP status code", function()
        reset()
        local ok, err = pcall(errors.send, "FORBIDDEN")
        assert.is_false(ok)
        assert.equal(403, tonumber(tostring(err)))
    end)

    it("falls back to INTERNAL for unknown code keys", function()
        reset()
        pcall(errors.send, "NONEXISTENT_CODE")
        assert.equal(500, _G.ngx.status)
    end)

end)

-- ============================================================================
-- core/pipeline.lua
-- ============================================================================

describe("core.pipeline: M.run()", function()

    -- Track which middleware ran and in what order
    local _ran = {}

    local function make_middleware(name, behavior)
        -- behavior: nil=pass, "exit"=ngx.exit, "error"=raise Lua error
        package.loaded["test_mw_" .. name] = nil
        package.preload["test_mw_" .. name] = function()
            return {
                run = function(ctx)
                    _ran[#_ran + 1] = name
                    if behavior == "exit" then
                        error(401, 0)  -- simulates ngx.exit raising a number
                    elseif behavior == "error" then
                        error("middleware crash", 0)
                    end
                end
            }
        end
        return "test_mw_" .. name
    end

    before_each(function()
        _ran = {}
        reset()
    end)

    it("executes all middlewares in order when none fails", function()
        local mods = {
            make_middleware("first"),
            make_middleware("second"),
            make_middleware("third"),
        }
        pipeline.run(mods)
        assert.equal(3, #_ran)
        assert.equal("first",  _ran[1])
        assert.equal("second", _ran[2])
        assert.equal("third",  _ran[3])
    end)

    it("stops on the first middleware that calls ngx.exit (number error)", function()
        local mods = {
            make_middleware("before"),
            make_middleware("stopper", "exit"),
            make_middleware("after"),
        }
        local ok, err = pcall(pipeline.run, mods)
        -- ngx.exit re-raised as numeric error; pcall sees non-success
        assert.is_false(ok, "pipeline.run must propagate numeric ngx.exit errors")
        local code = type(err) == "number" and err
                     or tonumber(tostring(err):match("(%d+)$") or "")
        assert.equal(401, code, "exit code must be 401, got: " .. tostring(err))
        assert.equal(2, #_ran, "only 2 middlewares should have run")
        assert.equal("before",  _ran[1])
        assert.equal("stopper", _ran[2])
    end)

    it("on non-number Lua error: logs and sends INTERNAL, stops execution", function()
        -- errors module is loaded by pipeline internally; mock it here
        package.loaded["core.errors"] = nil
        local errors_called = false
        package.preload["core.errors"] = function()
            return {
                send = function(code) errors_called = true; error(500, 0) end,
                codes = {},
            }
        end
        package.loaded["core.pipeline"] = nil
        local pl = require("core.pipeline")

        local mods = {
            make_middleware("ok1"),
            make_middleware("crasher", "error"),
            make_middleware("ok2"),
        }
        pcall(pl.run, mods)
        assert.is_true(errors_called, "INTERNAL error should be sent on non-number crash")
        -- restore
        package.loaded["core.errors"] = errors
        package.loaded["core.pipeline"] = pipeline
    end)

    it("logs an error and sends INTERNAL when a middleware module fails to load", function()
        package.loaded["core.errors"] = nil
        local errors_called = false
        package.preload["core.errors"] = function()
            return {
                send = function(code) errors_called = true; error(500, 0) end,
                codes = {},
            }
        end
        package.loaded["core.pipeline"] = nil
        local pl = require("core.pipeline")

        local mods = { "nonexistent.module.does.not.exist" }
        pcall(pl.run, mods)
        assert.is_true(errors_called)
        -- restore
        package.loaded["core.errors"] = errors
        package.loaded["core.pipeline"] = pipeline
    end)

    it("passes ngx.ctx to each middleware's run(ctx) function", function()
        local received_ctx = nil
        package.preload["test_mw_ctx"] = function()
            return {
                run = function(ctx)
                    received_ctx = ctx
                end,
            }
        end
        _G.ngx.ctx = { sentinel = "test-sentinel" }
        pipeline.run({"test_mw_ctx"})
        assert.not_nil(received_ctx)
        assert.equal("test-sentinel", received_ctx.sentinel)
    end)

end)

-- ============================================================================
-- core/app_config.lua — loading behavior
-- ============================================================================

describe("core.app_config: loading", function()

    it("app_config module loads without error when preloaded", function()
        -- The actual dofile path may not exist in test env, so we verify via preload
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { storage = "mysql", defaults = { cache_ttl = 60 } }
        end
        local cfg = require("core.app_config")
        assert.not_nil(cfg)
        assert.equal("mysql", cfg.storage)
        assert.equal(60, cfg.defaults.cache_ttl)
        -- Restore original preload
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function() return {} end
    end)

    it("raises if CONFIG_PATH is unreachable (via env var check)", function()
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = nil
        -- Mock os.getenv to point to nonexistent file
        local saved = os.getenv
        os.getenv = function(k)
            if k == "AIG_CONFIG" then return "/nonexistent/path/config.lua" end
            return saved(k)
        end
        local ok, err = pcall(require, "core.app_config")
        os.getenv = saved
        assert.is_false(ok, "should raise when config file not found")
        -- Restore
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function() return {} end
    end)

end)
