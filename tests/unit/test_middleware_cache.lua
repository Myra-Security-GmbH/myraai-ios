-- tests/unit/test_middleware_cache.lua — cache_check.lua + cache_store.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_cache.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _printed = nil
local _exited  = nil
local _headers = {}
local _log_buf = {}

_G.ngx = {
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function(s) _printed = s end,
    flush  = function() end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = {},
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
}

-- State (exact-match cache)
local _exact_cache   = {}
local _config_cache  = {}
local _store_calls   = {}

-- State mock
local function make_state_mock()
    return {
        cache_get  = function(k) return _exact_cache[k] end,
        cache_set  = function(k, v, ttl)
            _store_calls[#_store_calls + 1] = { key=k, val=v, ttl=ttl }
            _exact_cache[k] = v
        end,
        config_get = function(k) return _config_cache[k] end,
    }
end

-- Body reader
local _body_raw = nil

for _, n in ipairs({"middleware.cache_check","middleware.cache_store","cache.key",
                    "state","utils.json","utils.request","core.app_config","cache.semantic"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end

package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

package.preload["utils.request"] = function()
    return {
        read_body = function()
            return _body_raw
        end,
    }
end

-- Deterministic cache key builder
package.preload["cache.key"] = function()
    return {
        build = function(ctx)
            if not ctx.model then return nil end
            return "ck:" .. (ctx.model or "") .. ":" .. (_body_raw or "")
        end,
    }
end

package.loaded["state"] = make_state_mock()

local function reset()
    _printed     = nil
    _exited      = nil
    _headers     = {}
    _log_buf     = {}
    _body_raw    = nil
    _exact_cache = {}
    _config_cache= {}
    _store_calls = {}
    _G.ngx.status = 200
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end })
    _G.ngx.ctx    = {}
    package.loaded["state"] = make_state_mock()
end

local check = require("middleware.cache_check")
local store = require("middleware.cache_store")

local function make_ctx(cache_ttl, extra)
    local ctx = {
        gateway_id     = "gw-001",
        gateway_config = { cache_ttl = cache_ttl },
        log_fields     = {},
        request_id     = "req-cache",
    }
    if extra then for k, v in pairs(extra) do ctx[k] = v end end
    return ctx
end

-- ============================================================================
-- cache_check: skip conditions
-- ============================================================================

describe("middleware.cache_check: skip conditions", function()

    it("skips when cache_ttl = 0", function()
        reset()
        local ctx = make_ctx(0)
        local ok = pcall(check.run, ctx)
        assert.is_true(ok)
        assert.is_nil(ctx.cache_key, "cache_key must not be set when caching disabled")
    end)

    it("skips when cache_ttl is nil", function()
        reset()
        local ctx = make_ctx(nil)
        local ok = pcall(check.run, ctx)
        assert.is_true(ok)
        assert.is_nil(ctx.cache_key)
    end)

    it("skips when body cannot be read (nil body)", function()
        reset()
        _body_raw = nil
        local ctx = make_ctx(60)
        local ok = pcall(check.run, ctx)
        assert.is_true(ok)
        assert.is_nil(ctx.cache_key)
    end)

    it("skips when body is not valid JSON", function()
        reset()
        _body_raw = "not json"
        local ctx = make_ctx(60)
        local ok = pcall(check.run, ctx)
        assert.is_true(ok)
        assert.is_nil(ctx.cache_key)
    end)

end)

-- ============================================================================
-- cache_check: cache miss
-- ============================================================================

describe("middleware.cache_check: cache miss", function()

    it("sets ctx.cache_key on cache miss", function()
        reset()
        _body_raw = cjson.encode({ model="gpt-4o", messages={{role="user",content="hi"}} })
        local ctx = make_ctx(60)
        local ok = pcall(check.run, ctx)
        assert.is_true(ok)
        assert.not_nil(ctx.cache_key, "cache_key must be set on miss")
    end)

    it("does not set cache_hit on miss", function()
        reset()
        _body_raw = cjson.encode({ model="gpt-4o", messages={{}} })
        local ctx = make_ctx(60)
        pcall(check.run, ctx)
        assert.is_nil(ctx.cache_hit)
    end)

end)

-- ============================================================================
-- cache_check: exact cache hit
-- ============================================================================

describe("middleware.cache_check: exact cache hit", function()

    it("sets cache_hit, prints response body, exits 200 on hit", function()
        reset()
        _body_raw = cjson.encode({ model="gpt-4o", messages={{role="user",content="q"}} })
        -- Pre-populate cache
        local response_body = cjson.encode({ choices={{ message={ content="answer" } }} })
        local cache_key = "ck:gpt-4o:" .. _body_raw
        _exact_cache[cache_key] = cjson.encode({ body=response_body, cost_usd=0.001 })

        local ctx = make_ctx(60)
        local ok, err = pcall(check.run, ctx)
        assert.is_false(ok, "cache hit must exit via ngx.exit")
        assert.equal(200, tonumber(tostring(err):match("(%d+)$") or ""))
        assert.is_true(ctx.cache_hit)
        assert.equal("HIT", _headers["X-AIG-Cache"])
        assert.not_nil(_printed)
    end)

    it("records saved_cost_usd on cache hit", function()
        reset()
        _body_raw = cjson.encode({ model="m1", messages={{role="user",content="x"}} })
        local cache_key = "ck:m1:" .. _body_raw
        _exact_cache[cache_key] = cjson.encode({ body="{}", cost_usd=0.0042 })
        local ctx = make_ctx(60)
        pcall(check.run, ctx)
        assert.not_nil(ctx.log_fields.saved_cost_usd)
        assert.is_true(ctx.log_fields.saved_cost_usd > 0)
    end)

end)

-- ============================================================================
-- cache_store: skip conditions
-- ============================================================================

describe("middleware.cache_store: skip conditions", function()

    it("skips when is_streaming=true", function()
        reset()
        local ctx = make_ctx(60, {is_streaming=true, cache_key="k1",
                                   response_body='{}', provider_status=200})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

    it("skips when cache_hit=true", function()
        reset()
        local ctx = make_ctx(60, {is_streaming=false, cache_hit=true,
                                   cache_key="k2", response_body='{}', provider_status=200})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

    it("skips when no cache_key", function()
        reset()
        local ctx = make_ctx(60, {is_streaming=false, response_body='{}', provider_status=200})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

    it("skips when no response_body", function()
        reset()
        local ctx = make_ctx(60, {is_streaming=false, cache_key="k3", provider_status=200})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

    it("skips when provider_status != 200", function()
        reset()
        local ctx = make_ctx(60, {is_streaming=false, cache_key="k4",
                                   response_body='{}', provider_status=500})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

    it("skips when cache_ttl <= 0", function()
        reset()
        local ctx = make_ctx(0, {is_streaming=false, cache_key="k5",
                                  response_body='{}', provider_status=200})
        store.run(ctx)
        assert.equal(0, #_store_calls)
    end)

end)

-- ============================================================================
-- cache_store: successful storage
-- ============================================================================

describe("middleware.cache_store: successful storage", function()

    it("calls state.cache_set with encoded entry on success", function()
        reset()
        local ctx = make_ctx(120, {
            is_streaming  = false,
            cache_key     = "ck-store",
            response_body = cjson.encode({ choices={{message={content="ok"}}} }),
            provider_status = 200,
            cost_usd      = 0.007,
        })
        store.run(ctx)
        assert.equal(1, #_store_calls)
        assert.equal("ck-store", _store_calls[1].key)
        assert.equal(120, _store_calls[1].ttl)
        local entry = cjson.decode(_store_calls[1].val)
        assert.not_nil(entry.body)
        assert.equal(0.007, entry.cost_usd)
    end)

    it("defaults cost_usd to 0 when ctx.cost_usd is nil", function()
        reset()
        local ctx = make_ctx(60, {
            is_streaming  = false,
            cache_key     = "ck-nocost",
            response_body = '{}',
            provider_status = 200,
            cost_usd      = nil,
        })
        store.run(ctx)
        local entry = cjson.decode(_store_calls[1].val)
        assert.equal(0, entry.cost_usd)
    end)

end)
