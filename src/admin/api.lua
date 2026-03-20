-- admin/api.lua — REST admin API handler
-- Routes:
--   GET  /admin/v1/tenants
--   POST /admin/v1/tenants
--   GET  /admin/v1/tenants/:id/gateways
--   POST /admin/v1/tenants/:id/gateways
--   POST /admin/v1/tenants/:id/gateways/:gw/keys
--   GET  /admin/v1/tenants/:id/gateways/:gw/logs
--   GET  /admin/v1/tenants/:id/gateways/:gw/analytics
--   POST /admin/v1/gateways/:id/tokens

local json    = require("utils.json")
local storage = require("storage")
local byok    = require("auth.byok")
local crypto  = require("utils.crypto")

local M = {}

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
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

-- Simple path router
local ROUTES = {}

local function route(method, pattern, handler)
    ROUTES[#ROUTES + 1] = { method = method, pattern = pattern, handler = handler }
end

-- ---------------------------------------------------------------------------
-- Tenant routes
-- ---------------------------------------------------------------------------
route("POST", "^/admin/v1/tenants$", function()
    local b = read_body()
    if not b or not b.slug then
        return send(400, { error = "slug required" })
    end
    local id = storage.upsert_tenant(b.slug, b.plan, b.budget_usd)
    send(201, { id = id, slug = b.slug })
end)

-- ---------------------------------------------------------------------------
-- Gateway routes
-- ---------------------------------------------------------------------------
route("POST", "^/admin/v1/tenants/([^/]+)/gateways$", function(tenant_id)
    local b = read_body()
    if not b or not b.slug then
        return send(400, { error = "slug required" })
    end
    local id = storage.upsert_gateway(tenant_id, b.slug, b.config or {})
    send(201, { id = id, slug = b.slug })
end)

-- ---------------------------------------------------------------------------
-- BYOK key routes
-- ---------------------------------------------------------------------------
route("POST", "^/admin/v1/gateways/([^/]+)/keys$", function(gateway_id)
    local b = read_body()
    if not b or not b.provider or not b.key then
        return send(400, { error = "provider and key required" })
    end
    local err = byok.store_key(gateway_id, b.provider, b.alias or "default", b.key)
    if err then return send(500, { error = err }) end
    send(201, { ok = true, provider = b.provider, alias = b.alias or "default" })
end)

-- ---------------------------------------------------------------------------
-- Token routes
-- ---------------------------------------------------------------------------
route("POST", "^/admin/v1/gateways/([^/]+)/tokens$", function(gateway_id)
    local b = read_body()
    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local err = storage.insert_auth_token(gateway_id, hash,
                                          b and b.scopes or {}, b and b.expires_at)
    if err then return send(500, { error = err }) end
    -- Return raw token once — not stored in plaintext
    send(201, { token = raw_token, gateway_id = gateway_id })
end)

-- ---------------------------------------------------------------------------
-- Budget reset
-- ---------------------------------------------------------------------------
route("DELETE", "^/admin/v1/gateways/([^/]+)/budget$", function(gateway_id)
    local state = require("state")
    state.counter_incr("budget:" .. gateway_id,
        -(state.counter_get("budget:" .. gateway_id)))
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function M.handle()
    local method = ngx.req.get_method()
    local path   = ngx.var.uri

    for _, r in ipairs(ROUTES) do
        if r.method == method then
            local captures = { path:match(r.pattern) }
            if #captures > 0 then
                r.handler(table.unpack(captures))
                return
            end
        end
    end

    send(404, { error = "not found" })
end

return M
