-- tests/unit/test_state_backends.lua — covers:
--   state/shared_dict.lua, state/redis.lua, state/init.lua,
--   utils/redis.lua, storage/init.lua, utils/postgres.lua, storage/postgres.lua
-- Run with: resty tests/runner.lua tests/unit/test_state_backends.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ---------------------------------------------------------------------------
-- ngx stub with mock shared dicts
-- ---------------------------------------------------------------------------

local _dicts = {
    aig_cache     = {},
    aig_rate_limit = {},
    aig_metrics   = {},
    aig_byok      = {},
    aig_config    = {},
}

local function make_dict(store)
    local ttl_expiry = {}  -- key → expiry timestamp
    return {
        get = function(_, k)
            local exp = ttl_expiry[k]
            if exp and exp < _G.ngx.now() then store[k] = nil; ttl_expiry[k] = nil end
            return store[k]
        end,
        set = function(_, k, v, ttl)
            store[k] = v
            if ttl and ttl > 0 then ttl_expiry[k] = _G.ngx.now() + ttl end
            return true, nil, false
        end,
        delete = function(_, k) store[k] = nil end,
        incr   = function(_, k, delta, init, ttl)
            if store[k] == nil then store[k] = (init or 0) end
            store[k] = store[k] + (delta or 1)
            if ttl and ttl > 0 then ttl_expiry[k] = _G.ngx.now() + ttl end
            return store[k], nil
        end,
    }
end

local _ngx_time = 1700000000.0
_G.ngx = {
    now    = function() return _ngx_time end,
    log    = function() end,
    ERR    = 0, WARN = 1, INFO = 2,
    shared = {
        aig_cache      = make_dict(_dicts.aig_cache),
        aig_rate_limit = make_dict(_dicts.aig_rate_limit),
        aig_metrics    = make_dict(_dicts.aig_metrics),
        aig_byok       = make_dict(_dicts.aig_byok),
        aig_config     = make_dict(_dicts.aig_config),
    },
}

for _, n in ipairs({"state.shared_dict","state.redis","state","storage",
                    "storage.mysql","storage.sqlite","storage.postgres",
                    "utils.redis","utils.postgres","core.app_config",
                    "resty.redis","resty.mysql"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["storage.mysql"]    = function() return { init=function() end } end
package.preload["storage.sqlite"]   = function() return { init=function() end } end
package.preload["storage.postgres"] = function()
    return {
        init     = function() end,
        query    = function() return {}, nil end,
        get_conn = function() return {}, nil end,
    }
end

local function reset()
    _ngx_time = 1700000000.0
    for name, d in pairs(_dicts) do
        for k in pairs(d) do d[k] = nil end
        _G.ngx.shared[name] = make_dict(d)
    end
end

-- ============================================================================
-- state/shared_dict.lua: cache operations
-- ============================================================================

describe("state.shared_dict: cache_get / cache_set / cache_del", function()

    local function make_state()
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { shared_dict = {
                cache="aig_cache", rate_limit="aig_rate_limit",
                metrics="aig_metrics", byok="aig_byok", config="aig_config",
            }}
        end
        package.loaded["state.shared_dict"] = nil
        return require("state.shared_dict")
    end

    it("cache_set then cache_get returns the value", function()
        reset()
        local st = make_state()
        st.cache_set("my-key", "my-value", 60)
        assert.equal("my-value", st.cache_get("my-key"))
    end)

    it("cache_del removes the key", function()
        reset()
        local st = make_state()
        st.cache_set("del-key", "val", 0)
        st.cache_del("del-key")
        assert.is_nil(st.cache_get("del-key"))
    end)

    it("cache_get returns nil for non-existent key", function()
        reset()
        local st = make_state()
        assert.is_nil(st.cache_get("no-such-key"))
    end)

end)

describe("state.shared_dict: byok and config operations", function()

    local function make_state()
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { shared_dict = {
                cache="aig_cache", rate_limit="aig_rate_limit",
                metrics="aig_metrics", byok="aig_byok", config="aig_config",
            }}
        end
        package.loaded["state.shared_dict"] = nil
        return require("state.shared_dict")
    end

    it("byok_set then byok_get returns decrypted key", function()
        reset()
        local st = make_state()
        st.byok_set("byok:gw:prov:alias", "plaintext-key", 300)
        assert.equal("plaintext-key", st.byok_get("byok:gw:prov:alias"))
    end)

    it("config_set then config_get returns config value", function()
        reset()
        local st = make_state()
        st.config_set("gwcfg:acme:main", '{"cache_ttl":60}', 30)
        assert.equal('{"cache_ttl":60}', st.config_get("gwcfg:acme:main"))
    end)

end)

describe("state.shared_dict: counter operations", function()

    local function make_state()
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { shared_dict = {
                cache="aig_cache", rate_limit="aig_rate_limit",
                metrics="aig_metrics", byok="aig_byok", config="aig_config",
            }}
        end
        package.loaded["state.shared_dict"] = nil
        return require("state.shared_dict")
    end

    it("counter_incr initialises from zero and increments", function()
        reset()
        local st = make_state()
        local v1 = st.counter_incr("test-counter", 1)
        local v2 = st.counter_incr("test-counter", 1)
        assert.equal(1, v1)
        assert.equal(2, v2)
    end)

    it("counter_get returns current value", function()
        reset()
        local st = make_state()
        st.counter_incr("ctr", 5)
        assert.equal(5, st.counter_get("ctr"))
    end)

end)

-- ============================================================================
-- state/redis.lua: stub — all methods raise "not yet implemented"
-- ============================================================================

describe("state.redis: all methods raise not_implemented", function()

    it("cache_get raises", function()
        package.loaded["state.redis"] = nil
        local redis_state = require("state.redis")
        assert.has_error(function() redis_state.cache_get("k") end)
    end)

    it("cache_set raises", function()
        local redis_state = require("state.redis")
        assert.has_error(function() redis_state.cache_set("k","v",60) end)
    end)

    it("rate_limit_check raises", function()
        local redis_state = require("state.redis")
        assert.has_error(function() redis_state.rate_limit_check("k",60,10) end)
    end)

end)

-- ============================================================================
-- state/init.lua: backend dispatch
-- ============================================================================

describe("state/init.lua: dispatch", function()

    it("returns shared_dict backend when config.state = 'shared_dict'", function()
        package.loaded["state"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { state = "shared_dict", shared_dict = {
                cache="aig_cache", rate_limit="aig_rate_limit",
                metrics="aig_metrics", byok="aig_byok", config="aig_config",
            }}
        end
        local state = require("state")
        assert.equal("function", type(state.cache_get),
            "shared_dict backend must expose cache_get")
    end)

    it("returns redis backend when config.state = 'redis'", function()
        package.loaded["state"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { state = "redis" }
        end
        local state = require("state")
        assert.equal("function", type(state.cache_get),
            "redis backend must expose cache_get")
    end)

    it("raises for unknown state backend", function()
        package.loaded["state"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { state = "fakebackend" }
        end
        local ok = pcall(require, "state")
        assert.is_false(ok, "unknown backend must raise an error")
    end)

end)

-- ============================================================================
-- storage/init.lua: backend dispatch
-- ============================================================================

describe("storage/init.lua: dispatch", function()

    it("returns mysql backend when config.storage = 'mysql'", function()
        package.loaded["storage"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { storage = "mysql" }
        end
        local storage = require("storage")
        assert.not_nil(storage, "must return a module for mysql backend")
    end)

    it("returns postgres backend when config.storage = 'postgres'", function()
        package.loaded["storage"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { storage = "postgres" }
        end
        local storage = require("storage")
        assert.not_nil(storage)
    end)

    it("raises for unknown storage backend", function()
        package.loaded["storage"] = nil
        package.loaded["core.app_config"] = nil
        package.preload["core.app_config"] = function()
            return { storage = "fakedb" }
        end
        local ok = pcall(require, "storage")
        assert.is_false(ok, "unknown backend must raise an error")
    end)

end)

-- ============================================================================
-- utils/redis.lua: connect/release interface
-- ============================================================================

describe("utils.redis: connect/release interface", function()

    before_each(function()
        package.loaded["utils.redis"] = nil
        package.loaded["resty.redis"] = nil
        package.preload["resty.redis"] = function()
            return {
                new = function()
                    return {
                        set_timeout = function() end,
                        connect     = function() return true, nil end,
                        auth        = function() return true, nil end,
                        set_keepalive = function() return true, nil end,
                        evalsha     = function() return nil, "NOSCRIPT" end,
                        eval        = function() return "ok", nil end,
                    }
                end,
            }
        end
    end)

    it("connect() returns a redis object on success", function()
        local r = require("utils.redis")
        local red, err = r.connect()
        assert.is_nil(err)
        assert.not_nil(red)
    end)

    it("release() calls set_keepalive (returns connection to pool)", function()
        local r = require("utils.redis")
        local red, _ = r.connect()
        local keepalive_called = false
        red.set_keepalive = function() keepalive_called = true; return true, nil end
        r.release(red)
        assert.is_true(keepalive_called, "release must call set_keepalive")
    end)

    it("release() is a no-op for nil connection", function()
        local r = require("utils.redis")
        local ok = pcall(r.release, nil)
        assert.is_true(ok, "release(nil) must not raise")
    end)

    it("eval() retries with EVAL on NOSCRIPT error", function()
        local r = require("utils.redis")
        local red, _ = r.connect()
        local eval_calls = 0
        red.evalsha = function() return nil, "NOSCRIPT" end
        red.eval    = function(self, script, n, ...)
            eval_calls = eval_calls + 1
            return "result", nil
        end
        local res, err = r.eval(red, "return 1", "sha1", 0)
        assert.equal("result", res)
        assert.equal(1, eval_calls)
    end)

end)

-- ============================================================================
-- storage/postgres.lua + utils/postgres.lua: contract
-- ============================================================================

describe("storage.postgres + utils.postgres: module contract", function()

    it("storage.postgres exports init and the storage interface (stub implementations)", function()
        package.loaded["storage.postgres"] = nil
        package.preload["storage.postgres"] = nil
        local pg = require("storage.postgres")
        assert.equal("function", type(pg.init),       "must export init")
        assert.equal("function", type(pg.get_gateway), "must export get_gateway")
        assert.equal("function", type(pg.insert_log),  "must export insert_log")
        assert.equal("function", type(pg.get_usage_stats), "must export get_usage_stats")
    end)

    it("storage.postgres stub functions raise 'not yet implemented'", function()
        package.loaded["storage.postgres"] = nil
        package.preload["storage.postgres"] = nil
        local pg = require("storage.postgres")
        local ok, err = pcall(pg.get_gateway, "tenant", "gateway")
        assert.is_false(ok)
        assert(tostring(err):find("not yet implemented"),
            "stub must raise 'not yet implemented': " .. tostring(err))
    end)

end)
