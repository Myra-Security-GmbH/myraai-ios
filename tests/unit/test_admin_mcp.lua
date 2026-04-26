-- tests/unit/test_admin_mcp.lua — security and contract tests for admin/mcp.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_mcp.lua
--
-- Coverage:
--   1. auth_value redaction: absent from POST/PATCH/list responses, present in GET /:id
--   2. Tenant isolation: connectors from other tenants return 404
--   3. No tenant on caller → 403
--   4. Validation: name/server_url required, auth_type enum
--   5. POST /mcp/:id/call: auth header injection (bearer, header), JSON-RPC validation,
--      upstream error → 502

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

-- ---------------------------------------------------------------------------
-- ngx stub
-- ---------------------------------------------------------------------------
local _printed = nil
local _status  = 200

local _prev_e64 = _G.ngx and _G.ngx.encode_base64
local _prev_d64 = _G.ngx and _G.ngx.decode_base64

_G.ngx = {
    now           = function() return 1700000000.0 end,
    time          = function() return 1700000000 end,
    log           = function() end,
    exit          = function(code) _status = code end,
    encode_base64 = _prev_e64,
    decode_base64 = _prev_d64,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) end }),
    print  = function(s) _printed = s end,
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
        get_method    = function() return "GET" end,
        get_uri_args  = function() return {} end,
    },
    var    = { uri = "/", arg_gateway_id = "" },
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    escape_uri  = function(s) return s end,
    null        = cjson.null,
    timer       = { at = function() end },
}

-- ---------------------------------------------------------------------------
-- MCP connector fixture store
-- ---------------------------------------------------------------------------
local _conn_db = {}
local _http_last_opts = nil
local _http_response  = { body = cjson.encode({ result = "ok" }), err = nil }

local function seed(id, tenant_id, auth_type, auth_value)
    _conn_db[id] = {
        id         = id,
        tenant_id  = tenant_id,
        name       = "Connector " .. id,
        server_url = "https://mcp.example.com/" .. id,
        auth_type  = auth_type or "none",
        auth_value = auth_value,
    }
end

-- ---------------------------------------------------------------------------
-- Storage stub
-- ---------------------------------------------------------------------------
local _created_row = nil
local _updated_id  = nil

local storage_stub = {
    list_mcp_connectors = function(tenant_id, gw_id)
        local rows = {}
        for _, c in pairs(_conn_db) do
            if c.tenant_id == tenant_id then
                rows[#rows + 1] = { id = c.id, tenant_id = c.tenant_id,
                    name = c.name, server_url = c.server_url,
                    auth_type = c.auth_type
                    -- intentionally no auth_value in list
                }
            end
        end
        return rows
    end,
    create_mcp_connector = function(data)
        local id  = "conn-new-" .. os.time()
        local row = {
            id         = id,
            tenant_id  = data.tenant_id,
            name       = data.name,
            server_url = data.server_url,
            auth_type  = data.auth_type,
            auth_value = data.auth_value,
        }
        _conn_db[id]  = row
        _created_row  = row
        -- Return a shallow copy (simulating real storage returning the row)
        return { id = id, tenant_id = data.tenant_id, name = data.name,
                 server_url = data.server_url, auth_type = data.auth_type,
                 auth_value = data.auth_value }, nil
    end,
    get_mcp_connector = function(id)
        local c = _conn_db[id]
        if not c then return nil end
        return { id = c.id, tenant_id = c.tenant_id, name = c.name,
                 server_url = c.server_url, auth_type = c.auth_type,
                 auth_value = c.auth_value }
    end,
    update_mcp_connector = function(id, data)
        _updated_id = id
        local c = _conn_db[id]
        if not c then return false, "not found" end
        if data.name       then c.name       = data.name       end
        if data.server_url then c.server_url = data.server_url end
        if data.auth_type  then c.auth_type  = data.auth_type  end
        if data.auth_value ~= nil then c.auth_value = data.auth_value end
        return true, nil
    end,
    delete_mcp_connector = function(id)
        _conn_db[id] = nil
    end,
    -- Stubs for other modules loaded by admin.api
    get_usage_stats          = function() return {} end,
    list_tenants             = function() return {} end,
    list_audit_logs          = function() return {} end,
    insert_audit_log         = function() end,
}

-- ---------------------------------------------------------------------------
-- Module pre-loading
-- ---------------------------------------------------------------------------
local MODULES = {
    "admin.api", "admin.mcp", "admin.chat", "admin.projects",
    "admin.model_sync", "admin.monitor", "admin.share",
    "storage", "auth.byok", "utils.crypto", "utils.json",
    "providers", "core.app_config", "utils.uuid", "utils.http",
    "utils.email", "utils.trace", "utils.webhook",
}
for _, n in ipairs(MODULES) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

package.loaded["storage"] = storage_stub

package.preload["utils.json"] = function()
    return { encode = cjson.encode, decode = cjson.decode, null = cjson.null }
end
package.preload["utils.crypto"] = function()
    return { random_hex = function(n) return string.rep("b", n * 2) end }
end
package.preload["auth.byok"] = function()
    return { store_key = function() end, get_key = function() end }
end
package.preload["providers"] = function()
    return { list = function() return {} end }
end
package.preload["core.app_config"] = function()
    return { get = function() return {} end,
             shared_dict = { rate_limit = "rl", config = "cfg" } }
end
package.preload["utils.uuid"] = function()
    local n = 0
    return { v4 = function() n = n + 1; return "uuid-mcp-" .. n end }
end
package.preload["utils.email"] = function()
    return { send_template = function() end }
end
package.preload["utils.trace"] = function()
    return { record = function() end }
end
package.preload["utils.webhook"] = function()
    return { fire = function() end }
end
package.preload["utils.http"] = function()
    return {
        request = function(opts)
            _http_last_opts = opts
            if _http_response.err then
                return nil, _http_response.err
            end
            return _http_response.body, nil
        end,
    }
end

local api = require("admin.api")

-- ---------------------------------------------------------------------------
-- Test helper
-- ---------------------------------------------------------------------------
local function reset()
    _printed      = nil
    _status       = 200
    _created_row  = nil
    _updated_id   = nil
    _http_last_opts = nil
    _http_response  = { body = cjson.encode({ result = "ok" }), err = nil }
    ngx.status    = 200
    ngx.ctx.admin_user = { id = "u-1", role = "admin", tenant_id = "tn-owner" }
    ngx.var.arg_gateway_id = ""
end

local function call(method, uri, body_tbl, query_args, user_override)
    -- Do not call reset() here — before_each handles it so test-local
    -- state set before call() (e.g. _http_response.err) is preserved.
    if user_override then ngx.ctx.admin_user = user_override end
    ngx.req.get_method   = function() return method end
    ngx.req.get_uri_args = function() return query_args or {} end
    ngx.var.uri = uri

    if body_tbl ~= nil then
        local encoded = cjson.encode(body_tbl)
        ngx.req.get_body_data = function() return encoded end
    else
        ngx.req.get_body_data = function() return nil end
    end

    api.handle()

    local status = ngx.status ~= 200 and ngx.status or _status
    local decoded = _printed and (cjson.decode(_printed) or {}) or {}
    return status, decoded
end

-- ---------------------------------------------------------------------------
-- Helpers for assertions
-- ---------------------------------------------------------------------------
local function has_key(t, k)
    if type(t) ~= "table" then return false end
    return t[k] ~= nil and t[k] ~= cjson.null
end

-- ===========================================================================
-- Tests
-- ===========================================================================

describe("MCP: auth_value redaction", function()
    before_each(function() reset(); _conn_db = {} end)
    it("POST /mcp response never contains auth_value", function()
        local s, b = call("POST", "/admin/v1/mcp", {
            name       = "My Connector",
            server_url = "https://mcp.example.com",
            auth_type  = "bearer",
            auth_value = "super-secret-token",
        })
        assert.equal(201, s, "create must return 201: " .. tostring(s))
        assert.is_false(has_key(b, "auth_value"), "auth_value must not appear in POST response")
    end)

    it("PATCH /mcp/:id response never contains auth_value", function()
        seed("c-patch", "tn-owner", "bearer", "old-secret")
        local s, b = call("PATCH", "/admin/v1/mcp/c-patch", {
            auth_value = "new-secret",
        })
        assert.equal(200, s)
        assert.is_false(has_key(b, "auth_value"), "auth_value must not appear in PATCH response")
    end)

    it("GET /mcp/:id INCLUDES auth_value", function()
        seed("c-get", "tn-owner", "bearer", "readable-secret")
        local s, b = call("GET", "/admin/v1/mcp/c-get")
        assert.equal(200, s)
        assert.equal("readable-secret", b.auth_value)
    end)

    it("GET /mcp list rows have no auth_value", function()
        seed("c-list1", "tn-owner", "bearer", "list-secret-1")
        seed("c-list2", "tn-owner", "none",   nil)
        local s, b = call("GET", "/admin/v1/mcp")
        assert.equal(200, s)
        assert.is_true(type(b) == "table" and #b >= 1, "list must return rows")
        for _, row in ipairs(b) do
            assert.is_false(has_key(row, "auth_value"),
                "list row for '" .. tostring(row.id) .. "' must not expose auth_value")
        end
    end)
end)

describe("MCP: tenant isolation", function()
    before_each(function() reset(); _conn_db = {} end)
    it("GET /mcp/:id for other tenant's connector → 404", function()
        seed("c-other", "tn-other", "none", nil)
        local s, b = call("GET", "/admin/v1/mcp/c-other")
        assert.equal(404, s, "must return 404 for cross-tenant access")
    end)

    it("PATCH /mcp/:id for other tenant's connector → 404", function()
        seed("c-other-patch", "tn-other", "none", nil)
        local s = call("PATCH", "/admin/v1/mcp/c-other-patch", { name = "new name" })
        assert.equal(404, s)
    end)

    it("DELETE /mcp/:id for other tenant's connector → 404", function()
        seed("c-other-del", "tn-other", "none", nil)
        local s = call("DELETE", "/admin/v1/mcp/c-other-del")
        assert.equal(404, s)
    end)

    it("no tenant_id on caller → GET /mcp returns 403", function()
        local s, b = call("GET", "/admin/v1/mcp", nil, nil,
            { id = "u-notenant", role = "admin", tenant_id = nil })
        assert.equal(403, s)
    end)

    it("no tenant_id on caller → POST /mcp returns 403", function()
        local s, b = call("POST", "/admin/v1/mcp",
            { name = "x", server_url = "https://x.example.com" }, nil,
            { id = "u-notenant", role = "admin", tenant_id = nil })
        assert.equal(403, s)
    end)
end)

describe("MCP: validation", function()
    before_each(function() reset(); _conn_db = {} end)
    it("POST /mcp missing name → 400 with error about 'name'", function()
        local s, b = call("POST", "/admin/v1/mcp", {
            server_url = "https://mcp.example.com",
        })
        assert.equal(400, s)
        assert.not_nil(b.error)
        assert.match("name", b.error)
    end)

    it("POST /mcp missing server_url → 400 with error about 'server_url'", function()
        local s, b = call("POST", "/admin/v1/mcp", { name = "Test" })
        assert.equal(400, s)
        assert.not_nil(b.error)
        assert.match("server_url", b.error)
    end)

    it("POST /mcp with invalid auth_type → 400", function()
        local s, b = call("POST", "/admin/v1/mcp", {
            name       = "Bad Auth",
            server_url = "https://mcp.example.com",
            auth_type  = "oauth2",  -- unsupported
        })
        assert.equal(400, s)
        assert.not_nil(b.error)
    end)

    it("PATCH /mcp/:id with invalid auth_type → 400", function()
        seed("c-inv-patch", "tn-owner", "none", nil)
        local s, b = call("PATCH", "/admin/v1/mcp/c-inv-patch", { auth_type = "digest" })
        assert.equal(400, s)
        assert.not_nil(b.error)
    end)

    it("POST /mcp with valid auth_types none/bearer/header all accepted", function()
        for _, at in ipairs({ "none", "bearer", "header" }) do
            reset()
            local s = call("POST", "/admin/v1/mcp", {
                name       = "Test " .. at,
                server_url = "https://mcp.example.com",
                auth_type  = at,
            })
            assert.equal(201, s, "auth_type='" .. at .. "' must be accepted")
        end
    end)
end)

describe("MCP: call proxy auth header injection", function()
    before_each(function() reset(); _conn_db = {} end)
    it("bearer auth_type → Authorization: Bearer <token> forwarded", function()
        seed("c-bearer", "tn-owner", "bearer", "my-bearer-tok")
        local s, b = call("POST", "/admin/v1/mcp/c-bearer/call", {
            jsonrpc = "2.0",
            method  = "tools/list",
            id      = 1,
        })
        assert.equal(200, s, "call must succeed: " .. tostring(b.error))
        assert.not_nil(_http_last_opts, "http.request must have been called")
        local hdrs = _http_last_opts.headers or {}
        assert.equal("Bearer my-bearer-tok", hdrs["Authorization"])
    end)

    it("header auth_type → custom header parsed and forwarded", function()
        seed("c-hdr", "tn-owner", "header", "X-Api-Key: my-api-key-value")
        local s, b = call("POST", "/admin/v1/mcp/c-hdr/call", {
            jsonrpc = "2.0",
            method  = "tools/list",
            id      = 2,
        })
        assert.equal(200, s)
        assert.not_nil(_http_last_opts)
        local hdrs = _http_last_opts.headers or {}
        assert.equal("my-api-key-value", hdrs["X-Api-Key"])
    end)

    it("none auth_type → no Authorization header in outbound request", function()
        seed("c-none-call", "tn-owner", "none", nil)
        call("POST", "/admin/v1/mcp/c-none-call/call", {
            jsonrpc = "2.0", method = "ping", id = 3,
        })
        local hdrs = _http_last_opts and _http_last_opts.headers or {}
        assert.is_nil(hdrs["Authorization"])
    end)
end)

describe("MCP: call proxy validation", function()
    before_each(function() reset(); _conn_db = {} end)
    it("missing jsonrpc field → 400", function()
        seed("c-jrpc-miss", "tn-owner", "none", nil)
        local s, b = call("POST", "/admin/v1/mcp/c-jrpc-miss/call", {
            method = "tools/list", id = 1,
        })
        assert.equal(400, s)
        assert.not_nil(b.error)
    end)

    it("jsonrpc != '2.0' → 400", function()
        seed("c-jrpc-bad", "tn-owner", "none", nil)
        local s, b = call("POST", "/admin/v1/mcp/c-jrpc-bad/call", {
            jsonrpc = "1.0", method = "ping", id = 1,
        })
        assert.equal(400, s)
    end)

    it("missing method → 400", function()
        seed("c-nomethod", "tn-owner", "none", nil)
        local s, b = call("POST", "/admin/v1/mcp/c-nomethod/call", {
            jsonrpc = "2.0", id = 1,
        })
        assert.equal(400, s)
    end)

    it("HTTP upstream error → 502", function()
        seed("c-upstream-err", "tn-owner", "none", nil)
        _http_response = { body = nil, err = "connection refused" }
        local s, b = call("POST", "/admin/v1/mcp/c-upstream-err/call", {
            jsonrpc = "2.0", method = "ping", id = 1,
        })
        assert.equal(502, s)
        assert.not_nil(b.error)
    end)

    it("cross-tenant connector → 404 (not 403)", function()
        seed("c-cross-call", "tn-other", "none", nil)
        local s = call("POST", "/admin/v1/mcp/c-cross-call/call", {
            jsonrpc = "2.0", method = "ping", id = 1,
        })
        assert.equal(404, s)
    end)
end)
