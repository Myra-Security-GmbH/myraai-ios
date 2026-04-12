-- admin/mcp.lua — MCP connector CRUD + call-proxy routes
-- Routes are registered by calling M.register(route_fn) from admin/api.lua.
-- All routes require an authenticated session (ngx.ctx.admin_user must be set).
--
-- MCP connectors:
--   GET    /admin/v1/mcp                         list connectors for caller's tenant
--   POST   /admin/v1/mcp                         create connector
--   GET    /admin/v1/mcp/:id                     get connector (with auth_value)
--   PATCH  /admin/v1/mcp/:id                     update connector
--   DELETE /admin/v1/mcp/:id                     delete connector
-- MCP call proxy:
--   POST   /admin/v1/mcp/:id/call                proxy a JSON-RPC 2.0 call to the connector

local json      = require("utils.json")
local storage   = require("storage")
local http_util = require("utils.http")

local M = {}

local CORS_ORIGIN = os.getenv("AIG_ADMIN_CORS_ORIGIN")
local function cors_origin()
    return CORS_ORIGIN or ngx.var.http_origin or "*"
end

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"]                     = "application/json"
    ngx.header["Access-Control-Allow-Origin"]      = cors_origin()
    ngx.header["Access-Control-Allow-Credentials"] = "true"
    ngx.header["Access-Control-Allow-Headers"]     = "Content-Type, Authorization, x-aig-token"
    ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    ngx.print(json.encode(body))
end

local function read_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local f = ngx.req.get_body_file()
        if f then
            local fh = io.open(f, "rb")
            if fh then raw = fh:read("*a"); fh:close() end
        end
    end
    return json.decode(raw or "{}")
end

-- Returns the tenant_id for the current user; falls back to the admin-wide
-- tenant list for super-admins (not applicable here – MCP connectors are
-- tenant-scoped so the caller must have a tenant).
local function caller_tenant()
    local u = ngx.ctx.admin_user
    return u and u.tenant_id
end

-- Ensure the connector belongs to the caller's tenant.
local function assert_access(connector)
    local tid = caller_tenant()
    if not tid then return false end
    return connector.tenant_id == tid
end

function M.register(route)
    -- -----------------------------------------------------------------------
    -- GET /admin/v1/mcp — list connectors
    -- -----------------------------------------------------------------------
    route("GET", "^/admin/v1/mcp$", function()
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        local gw_id = ngx.var.arg_gateway_id
        local rows  = storage.list_mcp_connectors(tid, gw_id ~= "" and gw_id or nil)
        send(200, rows)
    end)

    -- -----------------------------------------------------------------------
    -- POST /admin/v1/mcp — create connector
    -- -----------------------------------------------------------------------
    route("POST", "^/admin/v1/mcp$", function()
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        local body = read_body()
        if not body.name or body.name == "" then
            return send(400, { error = "name is required" })
        end
        if not body.server_url or body.server_url == "" then
            return send(400, { error = "server_url is required" })
        end
        local auth_type = body.auth_type or "none"
        if auth_type ~= "none" and auth_type ~= "bearer" and auth_type ~= "header" then
            return send(400, { error = "auth_type must be none, bearer, or header" })
        end
        local data = {
            tenant_id  = tid,
            gateway_id = body.gateway_id,
            name       = body.name,
            server_url = body.server_url,
            auth_type  = auth_type,
            auth_value = body.auth_value,
        }
        local created, err = storage.create_mcp_connector(data)
        if not created then
            ngx.log(ngx.ERR, "create_mcp_connector: ", err)
            return send(500, { error = "failed to create connector" })
        end
        -- Never return auth_value in the list response
        created.auth_value = nil
        send(201, created)
    end)

    -- -----------------------------------------------------------------------
    -- GET /admin/v1/mcp/:id — get connector (includes auth_value)
    -- -----------------------------------------------------------------------
    route("GET", "^/admin/v1/mcp/([^/]+)$", function(id)
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        local row = storage.get_mcp_connector(id)
        if not row or row.tenant_id ~= tid then
            return send(404, { error = "not found" })
        end
        send(200, row)
    end)

    -- -----------------------------------------------------------------------
    -- PATCH /admin/v1/mcp/:id — update connector
    -- -----------------------------------------------------------------------
    route("PATCH", "^/admin/v1/mcp/([^/]+)$", function(id)
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        local row = storage.get_mcp_connector(id)
        if not row or row.tenant_id ~= tid then
            return send(404, { error = "not found" })
        end
        local body = read_body()
        local auth_type = body.auth_type
        if auth_type and auth_type ~= "none" and auth_type ~= "bearer" and auth_type ~= "header" then
            return send(400, { error = "auth_type must be none, bearer, or header" })
        end
        local ok, err = storage.update_mcp_connector(id, {
            name       = body.name,
            server_url = body.server_url,
            auth_type  = body.auth_type,
            auth_value = body.auth_value,
        })
        if not ok then
            ngx.log(ngx.ERR, "update_mcp_connector: ", err)
            return send(500, { error = "failed to update" })
        end
        local updated = storage.get_mcp_connector(id)
        updated.auth_value = nil
        send(200, updated)
    end)

    -- -----------------------------------------------------------------------
    -- DELETE /admin/v1/mcp/:id — delete connector
    -- -----------------------------------------------------------------------
    route("DELETE", "^/admin/v1/mcp/([^/]+)$", function(id)
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        local row = storage.get_mcp_connector(id)
        if not row or row.tenant_id ~= tid then
            return send(404, { error = "not found" })
        end
        storage.delete_mcp_connector(id)
        send(204, {})
    end)

    -- -----------------------------------------------------------------------
    -- POST /admin/v1/mcp/:id/call — proxy a JSON-RPC 2.0 call
    -- -----------------------------------------------------------------------
    route("POST", "^/admin/v1/mcp/([^/]+)/call$", function(id)
        local tid = caller_tenant()
        if not tid then return send(403, { error = "no tenant" }) end
        -- Fetch connector WITH auth_value
        local row = storage.get_mcp_connector(id)
        if not row or row.tenant_id ~= tid then
            return send(404, { error = "not found" })
        end
        local body = read_body()
        -- Must be a valid JSON-RPC 2.0 object
        if body.jsonrpc ~= "2.0" or not body.method then
            return send(400, { error = "must be a JSON-RPC 2.0 request" })
        end

        -- Build headers for the outbound call
        local req_headers = {
            ["Content-Type"] = "application/json",
            ["Accept"]       = "application/json",
        }
        if row.auth_type == "bearer" and row.auth_value and row.auth_value ~= ngx.null then
            req_headers["Authorization"] = "Bearer " .. tostring(row.auth_value)
        elseif row.auth_type == "header" and row.auth_value and row.auth_value ~= ngx.null then
            -- auth_value stored as "Header-Name: value"
            local hname, hval = tostring(row.auth_value):match("^([^:]+):%s*(.+)$")
            if hname and hval then
                req_headers[hname] = hval
            end
        end

        local res_body, err = http_util.request({
            method  = "POST",
            url     = row.server_url,
            headers = req_headers,
            body    = json.encode(body),
            timeout = 30000,
        })
        if not res_body then
            ngx.log(ngx.ERR, "mcp call error: ", err)
            return send(502, { error = "upstream MCP server error: " .. tostring(err) })
        end

        local parsed = json.decode(res_body)
        if parsed then
            send(200, parsed)
        else
            -- Return raw text on parse failure
            ngx.status = 200
            ngx.header["Content-Type"] = "text/plain"
            ngx.print(res_body)
        end
    end)
end

return M
