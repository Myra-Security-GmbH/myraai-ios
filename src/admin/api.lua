-- admin/api.lua — REST admin API handler
-- Routes:
--   GET    /admin/v1/tenants
--   POST   /admin/v1/tenants
--   GET    /admin/v1/tenants/:id/gateways
--   POST   /admin/v1/tenants/:id/gateways
--   GET    /admin/v1/tenants/:id/users
--   POST   /admin/v1/tenants/:id/users
--   GET    /admin/v1/gateways/:id
--   PATCH  /admin/v1/gateways/:id
--   GET    /admin/v1/gateways/:id/tokens
--   POST   /admin/v1/gateways/:id/tokens
--   DELETE /admin/v1/gateways/:id/tokens/:tid
--   POST   /admin/v1/gateways/:id/keys
--   DELETE /admin/v1/gateways/:id/budget
--   PATCH  /admin/v1/users/:id
--   DELETE /admin/v1/users/:id
--   GET    /admin/v1/users/:id/tokens
--   POST   /admin/v1/users/:id/tokens
--   GET    /admin/v1/users/:id/gateways
--   POST   /admin/v1/users/:id/gateways/:gw_id
--   DELETE /admin/v1/users/:id/gateways/:gw_id
--   DELETE /admin/v1/users/:id/budget
--   GET    /admin/v1/stats
--   GET    /admin/v1/stats/timeseries
--   GET    /admin/v1/logs
--   GET    /admin/v1/models
--   GET    /admin/v1/providers
--   POST   /admin/v1/playground/token
--   GET    /admin/v1/playground/search
--   POST   /admin/v1/client-errors
--   GET    /admin/v1/client-errors

local json         = require("utils.json")
local storage      = require("storage")
local byok         = require("auth.byok")
local crypto       = require("utils.crypto")
local providers_mod = require("providers")

local M = {}

-- Convert JSON null (cjson.null userdata) to Lua nil so SQLite bindings work.
local function nullable(v)
    return (v == json.null) and nil or v
end

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
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

local ROUTES = {}
local function route(method, pattern, handler)
    ROUTES[#ROUTES + 1] = { method = method, pattern = pattern, handler = handler }
end

-- ---------------------------------------------------------------------------
-- Stats & logs
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/stats$", function()
    send(200, storage.get_usage_stats())
end)

-- GET /admin/v1/stats/timeseries?bucket=1h&n=24
-- bucket: 5m | 15m | 30m | 1h (default) | 6h | 1d
-- n: number of buckets to return (default 24, max 168)
local BUCKET_SIZES = { ["5m"]=300, ["15m"]=900, ["30m"]=1800, ["1h"]=3600, ["6h"]=21600, ["1d"]=86400 }
route("GET", "^/admin/v1/stats/timeseries$", function()
    local args       = ngx.req.get_uri_args()
    local bucket_sec = BUCKET_SIZES[args.bucket or "1h"] or 3600
    local n          = math.min(math.max(tonumber(args.n) or 24, 1), 168)
    local end_sec = tonumber(args["until"])  -- optional unix seconds; defaults to now
    send(200, storage.get_stats_timeseries(bucket_sec, n, end_sec))
end)

route("GET", "^/admin/v1/logs$", function()
    local args = ngx.req.get_uri_args()
    send(200, storage.list_logs({
        tenant_id  = args.tenant_id,
        gateway_id = args.gateway_id,
        provider   = args.provider,
        since      = args.since,
        limit      = tonumber(args.limit),
        offset     = tonumber(args.offset),
    }))
end)

-- ---------------------------------------------------------------------------
-- Tenant routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants$", function()
    send(200, storage.list_tenants())
end)

route("POST", "^/admin/v1/tenants$", function()
    local b = read_body()
    if not b or not b.slug then return send(400, { error = "slug required" }) end
    local id = storage.upsert_tenant(b.slug, b.plan, b.budget_usd)
    send(201, { id = id, slug = b.slug })
end)

route("PATCH", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.update_tenant(tenant_id, b.plan, b.budget_usd)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    local err = storage.delete_tenant(tenant_id)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Gateway routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants/([^/]+)/gateways$", function(tenant_id)
    local rows = storage.list_gateways(tenant_id)
    for _, r in ipairs(rows) do r.config = json.decode(r.config or "{}") or {} end
    send(200, rows)
end)

route("POST", "^/admin/v1/tenants/([^/]+)/gateways$", function(tenant_id)
    local b = read_body()
    if not b or not b.slug then return send(400, { error = "slug required" }) end
    local id = storage.upsert_gateway(tenant_id, b.slug, b.config or {})
    send(201, { id = id, slug = b.slug })
end)

route("GET", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    local row = storage.get_gateway_by_id(gateway_id)
    if not row then return send(404, { error = "not found" }) end
    row.config = json.decode(row.config or "{}") or {}
    send(200, row)
end)

route("PATCH", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local row = storage.get_gateway_by_id(gateway_id)
    if not row then return send(404, { error = "not found" }) end
    local existing = json.decode(row.config or "{}") or {}
    if b.config then
        for k, v in pairs(b.config) do existing[k] = v end
    end
    storage.upsert_gateway(row.tenant_id, row.slug, existing)
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    local err = storage.delete_gateway(gateway_id)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- BYOK key routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/keys$", function(gateway_id)
    send(200, storage.list_provider_configs(gateway_id))
end)

route("POST", "^/admin/v1/gateways/([^/]+)/keys$", function(gateway_id)
    local b = read_body()
    if not b or not b.provider or not b.key then
        return send(400, { error = "provider and key required" })
    end
    local err = byok.store_key(gateway_id, b.provider, b.alias or "default", b.key)
    if err then return send(500, { error = err }) end
    send(201, { ok = true, provider = b.provider, alias = b.alias or "default" })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/keys/([^/]+)/([^/]+)$", function(gateway_id, provider, alias)
    local err = storage.delete_provider_config(gateway_id, provider, alias)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Routing rule routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/rules$", function(gateway_id)
    local rows = storage.list_routing_rules(gateway_id)
    for _, r in ipairs(rows) do
        r.conditions = json.decode(r.conditions or "[]") or {}
        r.actions    = json.decode(r.actions    or "{}") or {}
    end
    send(200, rows)
end)

route("POST", "^/admin/v1/gateways/([^/]+)/rules$", function(gateway_id)
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local new_id = storage.upsert_routing_rule(gateway_id, nil,
        b.priority, b.conditions, b.actions, b.enabled)
    send(201, { id = new_id })
end)

route("PATCH", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(gateway_id, rule_id)
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.upsert_routing_rule(gateway_id, rule_id,
        b.priority, b.conditions, b.actions, b.enabled)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(_, rule_id)
    storage.delete_routing_rule(rule_id)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Model price routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/model%-prices$", function()
    send(200, storage.list_model_prices())
end)

route("PUT", "^/admin/v1/model%-prices$", function()
    local b = read_body()
    if not b or not b.provider or not b.model then
        return send(400, { error = "provider and model required" })
    end
    local err = storage.upsert_model_price(b.provider, b.model,
        b.input_per_1k, b.output_per_1k, b.cache_write_per_1k, b.cache_read_per_1k)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/model%-prices/([^/]+)/(.+)$", function(provider, model)
    storage.delete_model_price(provider, model)
    send(200, { ok = true })
end)

-- Model catalog — read-only, supports ?provider= filter
-- GET /admin/v1/models
-- GET /admin/v1/models?provider=openrouter
route("GET", "^/admin/v1/models$", function()
    local args     = ngx.req.get_uri_args()
    local provider = args.provider
    if provider == "" then provider = nil end
    send(200, storage.list_models(provider))
end)

-- GET /admin/v1/providers
-- Returns provider metadata: name + whether an API key is required.
route("GET", "^/admin/v1/providers$", function()
    send(200, providers_mod.list())
end)

-- ---------------------------------------------------------------------------
-- Playground
-- ---------------------------------------------------------------------------

-- POST /admin/v1/playground/token
-- Creates a short-lived gateway auth token for use by the playground UI.
-- Returns the raw token, expiry, and slugs needed to construct the compat URL.
route("POST", "^/admin/v1/playground/token$", function()
    local b = read_body()
    if not b or not b.gateway_id then
        return send(400, { error = "gateway_id required" })
    end

    local gw = storage.get_gateway_with_tenant_slug(b.gateway_id)
    if not gw then return send(404, { error = "gateway not found" }) end

    -- Remove any previous playground tokens for this gateway before issuing a new one.
    storage.delete_playground_tokens(b.gateway_id)

    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    -- 10-minute TTL — enough for a playground session
    local expires_ts = os.time() + 600
    local expires_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", expires_ts)

    local _, err = storage.insert_auth_token(
        b.gateway_id, hash, {"playground"}, expires_ts,
        nil, "playground", nil, nil)
    if err then return send(500, { error = err }) end

    send(201, {
        token        = raw_token,
        expires_at   = expires_iso,
        tenant_slug  = gw.tenant_slug,
        gateway_slug = gw.gateway_slug,
    })
end)

-- GET /admin/v1/playground/search?q=...
-- Proxies a web search to Brave Search API and returns top organic results.
route("GET", "^/admin/v1/playground/search$", function()
    local args = ngx.req.get_uri_args()
    local q = args.q
    if not q or q == "" then return send(400, { error = "q required" }) end

    local http = require("utils.http")
    local status, _, body, err = http.request({
        method  = "GET",
        url     = "https://api.search.brave.com/res/v1/web/search?q="
                  .. ngx.escape_uri(q) .. "&count=5",
        headers = {
            ["Accept"]               = "application/json",
            ["X-Subscription-Token"] = "BSAaVsak7B8d0-0I_stOlzBal6EEncV",
        },
        timeout_ms = 8000,
    })
    if err then return send(502, { error = "search failed: " .. err }) end
    if status ~= 200 then return send(502, { error = "search API returned " .. tostring(status) }) end

    local data = json.decode(body) or {}
    local results = {}
    for _, r in ipairs((data.web or {}).results or {}) do
        results[#results + 1] = {
            title   = r.title,
            url     = r.url,
            snippet = r.description,
        }
    end
    send(200, { results = results, query = q })
end)

-- ---------------------------------------------------------------------------
-- Token routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/tokens$", function(gateway_id)
    send(200, storage.list_auth_tokens(gateway_id))
end)

route("POST", "^/admin/v1/gateways/([^/]+)/tokens$", function(gateway_id)
    local b = read_body()
    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b and b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(gateway_id, hash,
        b and b.scopes or {}, b and nullable(b.expires_at),
        nil, b and nullable(b.label), rate_limit_json, b and nullable(b.budget_usd))
    if err then return send(500, { error = err }) end
    send(201, { id = id, token = raw_token, gateway_id = gateway_id })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/tokens/([^/]+)$", function(_, token_id)
    storage.delete_auth_token(token_id)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- User routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants/([^/]+)/users$", function(tenant_id)
    send(200, storage.list_users(tenant_id))
end)

route("POST", "^/admin/v1/tenants/([^/]+)/users$", function(tenant_id)
    local b = read_body()
    if not b or not b.email then return send(400, { error = "email required" }) end
    local id, err = storage.insert_user(tenant_id, b.email, nullable(b.name), b.role)
    if err then return send(500, { error = err }) end
    send(201, { id = id, email = b.email })
end)

route("PATCH", "^/admin/v1/users/([^/]+)$", function(user_id)
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.update_user(user_id, nullable(b.email), nullable(b.name), b.role)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)$", function(user_id)
    local err = storage.delete_user(user_id)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

route("GET", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    send(200, storage.list_user_tokens(user_id))
end)

route("POST", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    local b = read_body()
    if not b or not b.gateway_id then return send(400, { error = "gateway_id required" }) end
    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(b.gateway_id, hash,
        b.scopes or {}, nullable(b.expires_at),
        user_id, nullable(b.label), rate_limit_json, nullable(b.budget_usd))
    if err then return send(500, { error = err }) end
    send(201, { id = id, token = raw_token, gateway_id = b.gateway_id })
end)

route("GET", "^/admin/v1/users/([^/]+)/gateways$", function(user_id)
    send(200, storage.list_user_gateways(user_id))
end)

route("POST", "^/admin/v1/users/([^/]+)/gateways/([^/]+)$", function(user_id, gateway_id)
    local err = storage.set_user_gateway_access(user_id, gateway_id)
    if err then return send(500, { error = err }) end
    send(201, { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)/gateways/([^/]+)$", function(user_id, gateway_id)
    local err = storage.delete_user_gateway_access(user_id, gateway_id)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)/budget$", function(user_id)
    local state = require("state")
    -- Reset all token budget counters for this user
    local tokens = storage.list_user_tokens(user_id)
    for _, t in ipairs(tokens) do
        local cur = state.counter_get("budget:token:" .. t.id) or 0
        if cur > 0 then state.counter_incr("budget:token:" .. t.id, -cur) end
    end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Client error reporting
-- ---------------------------------------------------------------------------
route("POST", "^/admin/v1/client%-errors$", function()
    local b = read_body()
    if not b or not b.message then return send(400, { error = "message required" }) end
    local id = b.id or require("utils.uuid").v4()
    local ts = b.ts or math.floor(ngx.now() * 1000)
    local err = storage.insert_client_error(
        id,
        tostring(b.message):sub(1, 2000),
        b.stack and tostring(b.stack):sub(1, 8000) or nil,
        b.url and tostring(b.url):sub(1, 500) or nil,
        b.user_agent and tostring(b.user_agent):sub(1, 500) or nil,
        ts
    )
    if err then return send(500, { error = err }) end
    send(201, { ok = true })
end)

route("GET", "^/admin/v1/client%-errors$", function()
    local args = ngx.req.get_uri_args()
    send(200, storage.list_client_errors(tonumber(args.limit)))
end)

-- ---------------------------------------------------------------------------
-- Budget reset
-- ---------------------------------------------------------------------------
route("DELETE", "^/admin/v1/gateways/([^/]+)/budget$", function(gateway_id)
    local state = require("state")
    local cur = state.counter_get("budget:" .. gateway_id) or 0
    if cur > 0 then state.counter_incr("budget:" .. gateway_id, -cur) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function M.handle()
    local method = ngx.req.get_method()
    local path   = ngx.var.uri

    -- CORS preflight
    if method == "OPTIONS" then
        ngx.header["Access-Control-Allow-Origin"]  = "*"
        ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
        ngx.status = 204
        ngx.exit(204)
        return
    end

    for _, r in ipairs(ROUTES) do
        if r.method == method then
            local captures = { path:match(r.pattern) }
            if #captures > 0 then
                r.handler(table.unpack(captures))
                return
            end
        end
    end

    -- Handle routes with no captures (exact matches)
    for _, r in ipairs(ROUTES) do
        if r.method == method and path:match(r.pattern) then
            r.handler()
            return
        end
    end

    send(404, { error = "not found" })
end

return M
