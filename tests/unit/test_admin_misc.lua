-- tests/unit/test_admin_misc.lua — tests for admin/monitor.lua, admin/share.lua,
--   admin/mcp.lua, admin/model_sync.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_misc.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _printed  = nil
local _said     = nil
local _status   = 200
local _headers  = {}
local _exited   = nil

_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function() end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function(s) _printed = s end,
    say    = function(s) _said = s end,
    flush  = function() end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = { uri = "/", remote_addr = "127.0.0.1" },
    req    = {
        get_method    = function() return "GET" end,
        get_headers   = function() return {} end,
        get_uri_args  = function() return {} end,
        read_body     = function() end,
        get_body_data = function() return "{}" end,
    },
    ctx    = {},
    shared = {
        aig_metrics = (function()
            local d = {}
            return {
                get = function(_, k) return d[k] end,
                set = function(_, k, v) d[k] = v end,
            }
        end)(),
    },
    ERR    = 0, WARN = 1, INFO = 2,
    timer  = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
}

for _, n in ipairs({"admin.monitor","admin.share","admin.mcp","admin.model_sync",
                    "storage","utils.json","core.app_config","admin.auth","utils.http",
                    "utils.uuid","guardrails.orchestrator","utils.crypto"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return { shared_dict = { metrics = "aig_metrics" } }
end
package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end
package.preload["utils.uuid"] = function()
    local n=0; return { v4=function() n=n+1; return "uuid-"..n end }
end
package.preload["utils.http"] = function()
    return { request=function() return 200, {}, '{"models":[]}', nil end }
end
package.preload["utils.crypto"] = function()
    return { sha256_hex=function(s) return "hash:"..s end, random_hex=function(n) return string.rep("a",n*2) end }
end

local _require_session_called = false
local _share_db = {}

package.preload["admin.auth"] = function()
    return {
        require_session = function()
            _require_session_called = true
        end,
        check_tenant = function() return true end,
    }
end

package.preload["storage"] = function()
    return {
        get_usage_stats = function() return { today={requests=5}, hour={}, last_min={}, by_tenant={}, recent={}, recent_blocked={} } end,
        get_share_by_token = function(tok) return _share_db[tok] end,
        list_mcp_connectors = function() return {} end,
        list_model_prices   = function() return {} end,
        upsert_model_price  = function() end,
        insert_audit_log    = function() end,
    }
end

local function reset()
    _printed = nil
    _said    = nil
    _exited  = nil
    _headers = {}
    _require_session_called = false
    _share_db = {}
    _G.ngx.status = 200
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end })
    _G.ngx.ctx    = {}
    _G.ngx.var.uri = "/"
    _G.ngx.req.get_method = function() return "GET" end
end

-- ============================================================================
-- admin/monitor.lua
-- ============================================================================

describe("admin.monitor: authentication guard", function()

    it("require_session() is called before any monitor handler runs", function()
        reset()
        _G.ngx.var.uri = "/monitor/stats"
        local monitor = require("admin.monitor")
        pcall(monitor.handle)
        assert.is_true(_require_session_called,
            "require_session() must be called before serving /monitor")
    end)

    it("require_session() is called for /monitor (dashboard) too", function()
        reset()
        _G.ngx.var.uri = "/monitor"
        local monitor = require("admin.monitor")
        pcall(monitor.handle)
        assert.is_true(_require_session_called)
    end)

end)

describe("admin.monitor: stats JSON structure", function()

    it("M.stats() outputs JSON with required top-level keys", function()
        reset()
        package.loaded["admin.monitor"] = nil
        local monitor = require("admin.monitor")
        pcall(monitor.stats)
        local out = _said or _printed
        assert.not_nil(out, "stats must produce output via ngx.say or ngx.print")
        local data = cjson.decode(out)
        assert.not_nil(data)
        assert.not_nil(data.now,      "stats must have 'now' field")
        assert.not_nil(data.live,     "stats must have 'live' field")
        assert.not_nil(data.recent,   "stats must have 'recent' field")
    end)

    it("M.stats() sets Content-Type: application/json", function()
        reset()
        package.loaded["admin.monitor"] = nil
        local monitor = require("admin.monitor")
        pcall(monitor.stats)
        assert.equal("application/json", _headers["Content-Type"])
    end)

end)

-- ============================================================================
-- admin/share.lua
-- ============================================================================

describe("admin.share: public share endpoint", function()

    local share = require("admin.share")

    it("returns 404 when token not found", function()
        reset()
        _G.ngx.var.uri = "/share/nonexistent-token-xyz"
        _G.ngx.req.get_method = function() return "GET" end
        share.handle()
        assert.equal(404, _G.ngx.status)
    end)

    it("returns 400 when no token in URI", function()
        reset()
        _G.ngx.var.uri = "/share/"
        _G.ngx.req.get_method = function() return "GET" end
        share.handle()
        assert.equal(400, _G.ngx.status)
    end)

    it("returns 200 with snapshot JSON when token is valid", function()
        reset()
        local snapshot = { title="test conv", messages={{ role="user", content="hi" }} }
        _share_db["valid-token-123"] = { snapshot_json = cjson.encode(snapshot) }
        _G.ngx.var.uri = "/share/valid-token-123"
        _G.ngx.req.get_method = function() return "GET" end
        share.handle()
        assert.equal(200, _G.ngx.status)
        assert.not_nil(_printed)
        local data = cjson.decode(_printed)
        assert.equal("test conv", data.title)
    end)

    it("sets Access-Control-Allow-Origin: * (public endpoint)", function()
        reset()
        local snapshot = { title="t", messages={} }
        _share_db["pub-tok"] = { snapshot_json = cjson.encode(snapshot) }
        _G.ngx.var.uri = "/share/pub-tok"
        _G.ngx.req.get_method = function() return "GET" end
        share.handle()
        assert.equal("*", _headers["Access-Control-Allow-Origin"])
    end)

    it("handles OPTIONS preflight with 204", function()
        reset()
        _G.ngx.var.uri = "/share/some-token"
        _G.ngx.req.get_method = function() return "OPTIONS" end
        _G.ngx.exit = function(c) _exited = c end  -- suppress error for this test
        share.handle()
        assert.equal(204, _G.ngx.status)
    end)

end)

-- ============================================================================
-- admin/mcp.lua
-- ============================================================================

describe("admin.mcp: module contract", function()

    it("exports M.register function", function()
        package.loaded["admin.mcp"] = nil
        local mcp = require("admin.mcp")
        assert.equal("function", type(mcp.register),
            "admin.mcp must export M.register(route)")
    end)

    it("M.register registers at least 4 routes", function()
        package.loaded["admin.mcp"] = nil
        local mcp = require("admin.mcp")
        local route_count = 0
        local function route(method, pattern, handler)
            route_count = route_count + 1
        end
        mcp.register(route)
        assert.is_true(route_count >= 4,
            "mcp must register at least 4 routes (GET/POST/PATCH/DELETE + call), got: " .. route_count)
    end)

end)

-- ============================================================================
-- admin/model_sync.lua
-- ============================================================================

describe("admin.model_sync: module contract", function()

    it("exports sync_provider, sync_all, start_timer", function()
        package.loaded["admin.model_sync"] = nil
        package.preload["admin.model_sync"] = nil
        local sync = require("admin.model_sync")
        assert.equal("function", type(sync.sync_provider), "sync_provider must be a function")
        assert.equal("function", type(sync.sync_all),      "sync_all must be a function")
        assert.equal("function", type(sync.start_timer),   "start_timer must be a function")
    end)

    it("sync_all() with nil provider does not raise", function()
        package.loaded["admin.model_sync"] = nil
        package.preload["admin.model_sync"] = nil
        local sync = require("admin.model_sync")
        local ok = pcall(sync.sync_all, nil)
        assert.is_true(ok, "sync_all(nil) must not raise")
    end)

end)
