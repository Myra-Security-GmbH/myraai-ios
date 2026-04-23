-- tests/unit/test_core_gateway.lua — unit tests for src/core/gateway.lua and src/core/config.lua
-- Run with: resty tests/runner.lua tests/unit/test_core_gateway.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local _log_buf = {}

_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) error(c, 0) end,
    print  = function() end,
    status = 200,
    header = {},
    var    = {},
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    timer  = { at = function() end },
}

for _, n in ipairs({"core.gateway","core.context","core.pipeline","core.config",
                    "core.app_config","core.errors","storage","state","utils.json","utils.uuid"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

-- Track pipeline.run invocations
local _pipeline_calls = {}  -- each entry: { mods = [...] }

package.preload["core.context"] = function()
    return { init = function() end }
end

package.preload["core.pipeline"] = function()
    return {
        run = function(middlewares)
            _pipeline_calls[#_pipeline_calls + 1] = { mods = middlewares }
        end,
    }
end

package.preload["core.app_config"] = function()
    return {
        storage = "mysql",
        defaults = {
            cache_ttl = 60, retry_count = 2, timeout_ms = 30000,
            config_cache_ttl = 60,
            prompt_caching       = { enabled = true },
            context_compaction   = { enabled = false },
        }
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

package.preload["utils.uuid"] = function()
    local n = 0
    return { v4 = function() n = n + 1; return "uuid-" .. n end }
end

-- State mock for config cache
local _config_cache = {}
package.preload["state"] = function()
    return {
        config_get = function(k) return _config_cache[k] end,
        config_set = function(k, v) _config_cache[k] = v end,
        init       = function() end,
    }
end

-- Storage mock
local _gw_store = {}
package.preload["storage"] = function()
    return {
        get_gateway = function(tenant, gw)
            local key = tenant .. "/" .. gw
            if _gw_store[key] then return _gw_store[key], nil end
            return nil, "not_found"
        end,
        init = function() end,
    }
end

-- Middleware/observability mocks (used by gateway.log())
local _log_ran = false
local _metrics_ran = false
package.preload["middleware.log"] = function()
    return { run = function() _log_ran = true end }
end
package.preload["observability.metrics"] = function()
    return { record = function() _metrics_ran = true end }
end

local gateway = require("core.gateway")
local config  = require("core.config")

local function reset()
    _pipeline_calls = {}
    _log_buf        = {}
    _log_ran        = false
    _metrics_ran    = false
    _gw_store       = {}
    _config_cache   = {}
    _G.ngx.ctx      = {}
    _G.ngx.status   = 200
end

-- ============================================================================
-- core/gateway.lua: phase handler structure
-- ============================================================================

describe("core.gateway: access() phase", function()

    it("calls context.init() and then pipeline.run(ACCESS_PIPELINE)", function()
        reset()
        local context_init_called = false
        package.loaded["core.context"] = nil
        package.preload["core.context"] = function()
            return { init = function() context_init_called = true end }
        end
        package.loaded["core.gateway"] = nil
        local gw = require("core.gateway")
        gw.access()
        assert.is_true(context_init_called, "context.init must be called in access()")
        assert.equal(1, #_pipeline_calls, "pipeline.run must be called once in access()")
        -- Restore
        package.loaded["core.gateway"] = gateway
    end)

    it("access() pipeline includes required auth middlewares", function()
        reset()
        gateway.access()
        assert.equal(1, #_pipeline_calls)
        local mods = _pipeline_calls[1].mods
        local mod_set = {}
        for _, m in ipairs(mods) do mod_set[m] = true end
        assert.is_true(mod_set["middleware.request_id"], "must include middleware.request_id")
        assert.is_true(mod_set["middleware.tenant"],     "must include middleware.tenant")
        assert.is_true(mod_set["middleware.auth"],       "must include middleware.auth")
        assert.is_true(mod_set["middleware.rate_limit"], "must include middleware.rate_limit")
    end)

end)

describe("core.gateway: content() phase", function()

    it("calls pipeline.run(CONTENT_PIPELINE)", function()
        reset()
        gateway.content()
        assert.equal(1, #_pipeline_calls)
    end)

    it("content() pipeline includes key processing middlewares", function()
        reset()
        gateway.content()
        local mods = _pipeline_calls[1].mods
        local mod_set = {}
        for _, m in ipairs(mods) do mod_set[m] = true end
        assert.is_true(mod_set["middleware.cache_check"],  "must include cache_check")
        assert.is_true(mod_set["middleware.upstream"],     "must include upstream")
        assert.is_true(mod_set["middleware.send_response"],"must include send_response")
        assert.is_true(mod_set["middleware.cost"],         "must include cost")
    end)

end)

describe("core.gateway: log() phase", function()

    it("calls middleware.log.run and metrics.record", function()
        reset()
        gateway.log()
        assert.is_true(_log_ran,     "middleware.log.run must be called in log()")
        assert.is_true(_metrics_ran, "metrics.record must be called in log()")
    end)

    it("log() phase errors are caught (pcall wrapped — does not crash nginx)", function()
        reset()
        package.loaded["middleware.log"] = nil
        package.preload["middleware.log"] = function()
            return { run = function() error("log failure") end }
        end
        package.loaded["core.gateway"] = nil
        local gw = require("core.gateway")
        local ok = pcall(gw.log)
        assert.is_true(ok, "log() must not raise even if middleware.log crashes")
        -- Restore
        package.loaded["middleware.log"] = nil
        package.preload["middleware.log"] = function()
            return { run = function() _log_ran = true end }
        end
        package.loaded["core.gateway"] = nil
        gateway = require("core.gateway")
    end)

end)

-- ============================================================================
-- core/config.lua: gateway config loading and caching
-- ============================================================================

describe("core.config: get_gateway()", function()

    it("returns config from storage on first call", function()
        reset()
        _gw_store["acme/main"] = {
            tenant_id = "tn-1", gateway_id = "gw-1", config = {},
        }
        local cfg = config.get_gateway("acme", "main")
        assert.not_nil(cfg)
        assert.equal("tn-1", cfg.tenant_id)
        assert.equal("gw-1", cfg.gateway_id)
    end)

    it("returns nil and sends TENANT_NOT_FOUND when gateway not in storage", function()
        reset()
        local ok, err = pcall(config.get_gateway, "noexist", "noexist")
        assert.is_false(ok)
        assert.equal("TENANT_NOT_FOUND", tostring(err))
    end)

    it("caches config in state backend on first load", function()
        reset()
        _gw_store["cached/gw"] = { tenant_id="tn-c", gateway_id="gw-c", config={} }
        config.get_gateway("cached", "gw")
        -- State cache should now have the entry
        local cache_key = "gwcfg:cached:gw"
        assert.not_nil(_config_cache[cache_key],
            "config must be stored in state cache after first load")
    end)

    it("returns cached config on second call (no storage hit)", function()
        reset()
        local cjson = require("cjson.safe")
        -- Pre-populate cache with known data
        local cached = { tenant_id="tn-cached", gateway_id="gw-cached", config={},
                         cache_ttl=60, retry_count=2, timeout_ms=30000,
                         log_payloads=true,
                         prompt_caching={enabled=true},
                         context_compaction={enabled=false} }
        _config_cache["gwcfg:myco:prod"] = cjson.encode(cached)
        -- Storage has nothing — if this is called, test fails
        local cfg = config.get_gateway("myco", "prod")
        assert.not_nil(cfg)
        assert.equal("tn-cached", cfg.tenant_id)
    end)

    it("applies default cache_ttl when gateway config has none", function()
        reset()
        _gw_store["def/gw"] = { tenant_id="tn-def", gateway_id="gw-def", config={} }
        local cfg = config.get_gateway("def", "gw")
        assert.not_nil(cfg.cache_ttl, "cache_ttl default must be applied")
        assert.not_nil(cfg.retry_count)
        assert.not_nil(cfg.timeout_ms)
    end)

end)
