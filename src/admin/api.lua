-- admin/api.lua — REST admin API handler
-- Routes:
--   GET    /admin/v1/tenants
--   POST   /admin/v1/tenants
--   GET    /admin/v1/tenants/:id/gateways
--   POST   /admin/v1/tenants/:id/gateways
--   GET    /admin/v1/organizations/:id/users
--   POST   /admin/v1/organizations/:id/users
--   GET    /admin/v1/gateways/:id
--   PATCH  /admin/v1/gateways/:id
--   GET    /admin/v1/gateways/:id/tokens
--   POST   /admin/v1/gateways/:id/tokens
--   DELETE /admin/v1/gateways/:id/tokens/:tid
--   POST   /admin/v1/gateways/:id/keys
--   GET    /admin/v1/gateways/:id/spend
--   DELETE /admin/v1/gateways/:id/budget
--   GET    /admin/v1/tenants/:id/spend
--   DELETE /admin/v1/tenants/:id/budget
--   GET    /admin/v1/tenants/:id/analytics
--   PATCH  /admin/v1/users/:id
--   DELETE /admin/v1/users/:id
--   GET    /admin/v1/users/:id/tokens
--   POST   /admin/v1/users/:id/tokens
--   DELETE /admin/v1/users/:id/budget
--   GET    /admin/v1/stats
--   GET    /admin/v1/stats/timeseries
--   GET    /admin/v1/logs
--   GET    /admin/v1/models
--   GET    /admin/v1/providers
--   POST   /admin/v1/playground/token
--   GET    /admin/v1/playground/search
--   GET    /admin/v1/playground/trace/:id
--   POST   /admin/v1/client-errors
--   GET    /admin/v1/client-errors
--   GET    /admin/v1/audit-log

local json         = require("utils.json")
local storage      = require("storage")
local byok         = require("auth.byok")
local crypto       = require("utils.crypto")
local providers_mod = require("providers")
local auth         = require("admin.auth")

local M = {}

local CORS_ORIGIN = os.getenv("AIG_ADMIN_CORS_ORIGIN")
-- When no explicit origin is configured, echo the request's Origin header.
-- Sending "Access-Control-Allow-Origin: *" with "Allow-Credentials: true" is
-- forbidden by the CORS spec; browsers reject it for credentialed requests.
local function cors_origin()
    return CORS_ORIGIN or ngx.var.http_origin or "*"
end

-- Error format note: the admin API uses a flat {"error": "message"} shape,
-- intentionally simpler than the inference API's {"error": {"code": "...", "message": "..."}}
-- (core/errors.lua). The admin API is consumed only by the admin UI and operator
-- tooling; the structured code field is not needed here.

-- Convert JSON null (cjson.null userdata) to Lua nil so SQLite bindings work.
local function nullable(v)
    if v == json.null then return nil end
    return v
end

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"]                     = "application/json"
    ngx.header["Access-Control-Allow-Origin"]      = cors_origin()
    ngx.header["Access-Control-Allow-Credentials"] = "true"
    ngx.header["Access-Control-Allow-Headers"]     = "Content-Type, Authorization, x-aig-token"
    ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, PATCH, DELETE, OPTIONS"
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

-- ---------------------------------------------------------------------------
-- Ownership helpers — enforce org-scoped resource isolation
-- ---------------------------------------------------------------------------

-- Verifies tenant is accessible to the current user.
-- Returns tenant row, or sends 403/404 and returns nil.
local function require_tenant_access(tenant_id)
    local u = ngx.ctx.admin_user
    local t = storage.get_tenant(tenant_id)
    if not t then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and t.organization_id ~= u.org_id then
        send(403, { error = "forbidden" }); return nil
    end
    return t
end

-- Verifies gateway's owning tenant is accessible. Returns gateway row or nil.
local function require_gateway_access(gateway_id)
    local u = ngx.ctx.admin_user
    local gw = storage.get_gateway_by_id(gateway_id)
    if not gw then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and not storage.tenant_in_org(gw.tenant_id, u.org_id) then
        send(403, { error = "forbidden" }); return nil
    end
    return gw
end

-- Verifies user belongs to the same org as the caller. Returns user row or nil.
local function require_user_access(user_id)
    local u = ngx.ctx.admin_user
    local usr = storage.get_user(user_id)
    if not usr then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and usr.organization_id ~= u.org_id then
        send(403, { error = "forbidden" }); return nil
    end
    return usr
end

local ROUTES = {}
local function route(method, pattern, handler)
    ROUTES[#ROUTES + 1] = { method = method, pattern = pattern, handler = handler }
end

-- ---------------------------------------------------------------------------
-- Stats & logs
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/stats$", function()
    local args = ngx.req.get_uri_args()
    local u = ngx.ctx.admin_user
    local org_filter = (u.role ~= "admin") and u.org_id or nil
    send(200, storage.get_usage_stats(args.tenant_id, org_filter))
end)

-- GET /admin/v1/stats/timeseries?bucket=1h&n=24[&tenant_id=X]
-- bucket: 5m | 15m | 30m | 1h (default) | 6h | 1d
-- n: number of buckets to return (default 24, max 168)
local BUCKET_SIZES = { ["5m"]=300, ["15m"]=900, ["30m"]=1800, ["1h"]=3600, ["6h"]=21600, ["1d"]=86400 }
route("GET", "^/admin/v1/stats/timeseries$", function()
    local args       = ngx.req.get_uri_args()
    local bucket_sec = BUCKET_SIZES[args.bucket or "1h"] or 3600
    local n          = math.min(math.max(tonumber(args.n) or 24, 1), 168)
    local end_sec    = tonumber(args["until"])
    local tenant_id  = (args.tenant_id ~= nil and args.tenant_id ~= "") and args.tenant_id or nil
    local u = ngx.ctx.admin_user
    local org_filter = (u.role ~= "admin") and u.org_id or nil
    send(200, storage.get_stats_timeseries(bucket_sec, n, end_sec, tenant_id, org_filter))
end)

route("GET", "^/admin/v1/logs$", function()
    local args = ngx.req.get_uri_args()
    local u = ngx.ctx.admin_user
    local org_filter = (u.role ~= "admin") and u.org_id or nil
    send(200, storage.list_logs({
        org_id            = org_filter,
        tenant_id         = args.tenant_id,
        gateway_id        = args.gateway_id,
        provider          = args.provider,
        model             = args.model,
        status            = args.status,
        blocked           = args.blocked,
        since             = tonumber(args.since),
        guardrail_outcome = args.guardrail_outcome,
        limit             = tonumber(args.limit),
        offset            = tonumber(args.offset),
    }))
end)

-- GET /admin/v1/stats/analytics?since=<unix_ms>
-- Returns latency percentiles (p50/p95/p99) and top models by request volume.
route("GET", "^/admin/v1/stats/analytics$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local args    = ngx.req.get_uri_args()
    local since   = tonumber(args.since)
    send(200, storage.get_analytics_depth(since))
end)

route("GET", "^/admin/v1/logs/([^/]+)$", function(id)
    local entry = storage.get_log(id)
    if not entry then return send(404, { error = "not found" }) end
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and not storage.tenant_in_org(entry.tenant_id, u.org_id) then
        return send(403, { error = "forbidden" })
    end
    send(200, entry)
end)

-- ---------------------------------------------------------------------------
-- Tenant routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants$", function()
    local u = ngx.ctx.admin_user
    local org_filter = (u.role ~= "admin") and u.org_id or nil
    local rows = storage.list_tenants(org_filter)
    local cjson = require("cjson.safe")
    for _, r in ipairs(rows) do
        r.siem = r.siem_config and json.decode(r.siem_config) or nil
        r.siem_config = nil
        if r.organization_id == nil then r.organization_id = cjson.null end
    end
    send(200, rows)
end)

route("POST", "^/admin/v1/tenants$", function()
    local u = ngx.ctx.admin_user
    local b = read_body()
    if not b or not b.slug then return send(400, { error = "slug required" }) end
    local siem_json = b.siem and json.encode(b.siem) or nil
    -- non-platform-admin users always create within their own org
    local org_id = (u.role ~= "admin") and u.org_id or b.organization_id
    local id = storage.upsert_tenant(b.slug, b.plan, b.budget_usd, b.budget_period, siem_json, org_id)
    send(201, { id = id, slug = b.slug, organization_id = org_id })
end)

route("PATCH", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    local u = ngx.ctx.admin_user
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    -- non-platform-admin: verify the tenant belongs to their org
    if u.role ~= "admin" then
        local t = storage.get_tenant(tenant_id)
        if not t or t.organization_id ~= u.org_id then
            return send(403, { error = "forbidden" })
        end
    end
    local siem_json = (type(b.siem) == "table") and json.encode(b.siem) or nil
    -- org_id sentinel: false = not in body (don't touch), nil/string = explicit value
    local org_id
    if u.role ~= "admin" then
        org_id = false           -- non-platform-admin cannot change org assignment
    elseif b.organization_id ~= nil then
        org_id = b.organization_id   -- nil clears, string sets
    else
        org_id = false           -- key absent from body → don't touch
    end
    local err = storage.update_tenant(tenant_id, b.plan, b.budget_usd, b.budget_period, siem_json, org_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local err = storage.delete_tenant(tenant_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Gateway routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants/([^/]+)/gateways$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local rows = storage.list_gateways(tenant_id)
    for _, r in ipairs(rows) do r.config = json.decode(r.config or "{}") or {} end
    send(200, rows)
end)

route("POST", "^/admin/v1/tenants/([^/]+)/gateways$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local b = read_body()
    if not b or not b.slug then return send(400, { error = "slug required" }) end
    local id = storage.upsert_gateway(tenant_id, b.slug, b.config or {})
    send(201, { id = id, slug = b.slug })
end)

route("GET", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    local row = require_gateway_access(gateway_id)
    if not row then return end
    row.config = json.decode(row.config or "{}") or {}
    send(200, row)
end)

route("PATCH", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    local row = require_gateway_access(gateway_id)
    if not row then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local existing = json.decode(row.config or "{}") or {}
    if b.config then
        for k, v in pairs(b.config) do existing[k] = v end
    end
    storage.upsert_gateway(row.tenant_id, row.slug, existing)
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local err = storage.delete_gateway(gateway_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- BYOK key routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/keys$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    send(200, storage.list_provider_configs(gateway_id))
end)

route("POST", "^/admin/v1/gateways/([^/]+)/keys$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    if not b or not b.provider or not b.key then
        return send(400, { error = "provider and key required" })
    end
    local err = byok.store_key(gateway_id, b.provider, b.alias or "default", b.key)
    if err then return send(500, { error = tostring(err) }) end
    send(201, { ok = true, provider = b.provider, alias = b.alias or "default" })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/keys/([^/]+)/([^/]+)$", function(gateway_id, provider, alias)
    if not require_gateway_access(gateway_id) then return end
    local err = storage.delete_provider_config(gateway_id, provider, alias)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Routing rule routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/rules$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local rows = storage.list_routing_rules(gateway_id)
    for _, r in ipairs(rows) do
        r.conditions = json.decode(r.conditions or "[]") or {}
        r.actions    = json.decode(r.actions    or "{}") or {}
    end
    send(200, rows)
end)

route("POST", "^/admin/v1/gateways/([^/]+)/rules$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local new_id = storage.upsert_routing_rule(gateway_id, nil,
        b.priority, b.conditions, b.actions, b.enabled)
    send(201, { id = new_id })
end)

route("PATCH", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(gateway_id, rule_id)
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.upsert_routing_rule(gateway_id, rule_id,
        b.priority, b.conditions, b.actions, b.enabled)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(gateway_id, rule_id)
    if not require_gateway_access(gateway_id) then return end
    storage.delete_routing_rule(rule_id)
    send(200, { ok = true })
end)

route("GET", "^/admin/v1/gateways/([^/]+)/circuit%-breaker$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local cfg_mod  = require("core.app_config")
    local cb       = require("core.circuit_breaker")
    local rl_dict  = ngx.shared[cfg_mod.shared_dict.rate_limit]
    local cfg_dict = ngx.shared[cfg_mod.shared_dict.config]

    -- Collect all providers that have CB keys in the shared dicts
    local providers_seen = {}
    local prefix = "cb:state:" .. gateway_id .. ":"
    -- Walk the config dict for state keys belonging to this gateway
    local keys_list = cfg_dict:get_keys(0)  -- 0 = no limit
    for _, k in ipairs(keys_list or {}) do
        local prov = k:match("^cb:state:" .. gateway_id .. ":(.+)$")
        if prov then providers_seen[prov] = true end
    end

    local result = {}
    for prov in pairs(providers_seen) do
        local state_val  = cfg_dict:get("cb:state:"   .. gateway_id .. ":" .. prov) or "closed"
        local opened_at  = tonumber(cfg_dict:get("cb:opened:" .. gateway_id .. ":" .. prov))
        local fail_count = rl_dict:get("cb:fail:"    .. gateway_id .. ":" .. prov) or 0
        local entry = { state = state_val, failures = fail_count }
        if opened_at then entry.opened_at = opened_at end
        result[prov] = entry
    end
    send(200, result)
end)

route("GET", "^/admin/v1/gateways/([^/]+)/guardrail%-stats$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    send(200, storage.get_gateway_guardrail_stats(gateway_id))
end)

route("GET", "^/admin/v1/gateways/([^/]+)/guardrail%-events$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local args = ngx.req.get_uri_args()
    send(200, storage.list_guardrail_events(gateway_id, tonumber(args.limit)))
end)

-- ---------------------------------------------------------------------------
-- Model price routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/model%-prices$", function()
    send(200, storage.list_model_prices())
end)

route("PUT", "^/admin/v1/model%-prices$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local b = read_body()
    if not b or not b.provider or not b.model then
        return send(400, { error = "provider and model required" })
    end
    local err = storage.upsert_model_price(b.provider, b.model,
        b.input_per_1k, b.output_per_1k, b.cache_write_per_1k, b.cache_read_per_1k)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/model%-prices/([^/]+)/(.+)$", function(provider, model)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
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

    if not require_gateway_access(b.gateway_id) then return end

    local gw = storage.get_gateway_with_tenant_slug(b.gateway_id)
    if not gw then return send(404, { error = "gateway not found" }) end

    -- Remove only *expired* playground tokens for this gateway.
    -- Do not delete valid tokens — that would invalidate concurrent sessions
    -- (e.g. another browser tab or a Playwright test run).
    storage.delete_expired_playground_tokens(b.gateway_id)

    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    -- 10-minute TTL — enough for a playground session
    local expires_ts = os.time() + 600
    local expires_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", expires_ts)

    local _, err = storage.insert_auth_token(
        b.gateway_id, hash, {"playground"}, expires_ts,
        nil, "playground", nil, nil)
    if err then return send(500, { error = tostring(err) }) end

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

-- GET /admin/v1/gateways/:id/traces  — list recent gateway-level request traces
route("GET", "^/admin/v1/gateways/([^/]+)/traces$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local limit = math.min(tonumber(ngx.var.arg_limit) or 50, 200)
    send(200, storage.list_gateway_traces(gateway_id, limit))
end)

-- GET /admin/v1/traces/:id  — fetch any trace (gateway or playground) by ID
route("GET", "^/admin/v1/traces/([^/]+)$", function(trace_id)
    local t = storage.get_playground_trace(trace_id)
    if not t then return send(404, { error = "trace not found" }) end
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and t.gateway_id then
        if not require_gateway_access(t.gateway_id) then return end
    end
    local steps = storage.get_playground_trace_steps(trace_id)
    for _, s in ipairs(steps) do s.data = json.decode(s.data) or s.data end
    return send(200, { trace = t, steps = steps })
end)

-- GET /admin/v1/playground/trace/:id
route("GET", "^/admin/v1/playground/trace/([^/]+)$", function(trace_id)
    local t = storage.get_playground_trace(trace_id)
    if not t then
        return send(404, { error = "trace not found" })
    end
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and t.gateway_id then
        if not require_gateway_access(t.gateway_id) then return end
    end
    local steps = storage.get_playground_trace_steps(trace_id)
    -- Decode JSON data fields
    for _, s in ipairs(steps) do
        s.data = json.decode(s.data) or s.data
    end
    return send(200, { trace = t, steps = steps })
end)

-- ---------------------------------------------------------------------------
-- Token routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/gateways/([^/]+)/tokens$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    send(200, storage.list_auth_tokens(gateway_id))
end)

route("POST", "^/admin/v1/gateways/([^/]+)/tokens$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b and b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(gateway_id, hash,
        b and b.scopes or {}, b and nullable(b.expires_at),
        b and nullable(b.user_id), b and nullable(b.label), rate_limit_json, b and nullable(b.budget_usd))
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, token = raw_token, gateway_id = gateway_id })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/tokens/([^/]+)$", function(gateway_id, token_id)
    if not require_gateway_access(gateway_id) then return end
    storage.delete_auth_token(token_id)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- User routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/organizations/([^/]+)/users$", function(org_id)
    if not auth.check_org(org_id) then return send(403, { error = "forbidden" }) end
    send(200, storage.list_users(org_id))
end)

route("POST", "^/admin/v1/organizations/([^/]+)/users$", function(org_id)
    if not auth.check_org(org_id) then return send(403, { error = "forbidden" }) end
    local b = read_body()
    if not b or not b.email then return send(400, { error = "email required" }) end
    local id, err = storage.insert_user(org_id, b.email, nullable(b.name), b.role)
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, email = b.email })
end)

route("PATCH", "^/admin/v1/users/([^/]+)$", function(user_id)
    if not require_user_access(user_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.update_user(user_id, nullable(b.email), nullable(b.name), b.role)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)$", function(user_id)
    if not require_user_access(user_id) then return end
    local err = storage.delete_user(user_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("GET", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    if not require_user_access(user_id) then return end
    send(200, storage.list_user_tokens(user_id))
end)

route("POST", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    if not require_user_access(user_id) then return end
    local b = read_body()
    if not b or not b.gateway_id then return send(400, { error = "gateway_id required" }) end
    if not require_gateway_access(b.gateway_id) then return end
    local raw_token = crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(b.gateway_id, hash,
        b.scopes or {}, nullable(b.expires_at),
        user_id, nullable(b.label), rate_limit_json, nullable(b.budget_usd))
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, token = raw_token, gateway_id = b.gateway_id })
end)

route("DELETE", "^/admin/v1/users/([^/]+)/budget$", function(user_id)
    if not require_user_access(user_id) then return end
    -- Reset spend_ledger for all tokens belonging to this user
    local tokens = storage.list_user_tokens(user_id)
    for _, t in ipairs(tokens) do
        storage.reset_spend("token", t.id)
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
    if err then return send(500, { error = tostring(err) }) end
    send(201, { ok = true })
end)

route("GET", "^/admin/v1/client%-errors$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local args = ngx.req.get_uri_args()
    send(200, storage.list_client_errors(tonumber(args.limit)))
end)

-- GET /admin/v1/audit-log?limit=100&offset=0
route("GET", "^/admin/v1/audit%-log$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local args = ngx.req.get_uri_args()
    send(200, storage.list_audit_logs(tonumber(args.limit), tonumber(args.offset)))
end)

-- ---------------------------------------------------------------------------
-- Budget: spend history and reset
-- ---------------------------------------------------------------------------

-- GET /admin/v1/gateways/:id/spend  — spend history (all periods)
route("GET", "^/admin/v1/gateways/([^/]+)/spend$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local args  = ngx.req.get_uri_args()
    local limit = tonumber(args.limit) or 12
    local rows  = storage.get_spend_history("gateway", gateway_id, limit)
    -- Enrich: convert amount_micro → amount_usd
    for _, r in ipairs(rows) do r.amount_usd = r.amount_micro / 1e6 end
    send(200, rows)
end)

-- GET /admin/v1/tenants/:id/analytics?since=<unix_ms>&bucket=<bucket>&n=<n>
-- Returns per-tenant timeseries + top models for the analytics detail panel.
route("GET", "^/admin/v1/tenants/([^/]+)/analytics$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local args       = ngx.req.get_uri_args()
    local since      = tonumber(args.since)
    local bucket_sec = BUCKET_SIZES[args.bucket or "1d"] or 86400
    local n          = math.min(math.max(tonumber(args.n) or 30, 1), 168)
    local timeseries = storage.get_stats_timeseries(bucket_sec, n, nil, tenant_id)
    local top_models = storage.get_tenant_top_models(tenant_id, since)
    send(200, { timeseries = timeseries, top_models = top_models })
end)

-- GET /admin/v1/tenants/:id/spend  — tenant spend history (all periods)
route("GET", "^/admin/v1/tenants/([^/]+)/spend$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local args  = ngx.req.get_uri_args()
    local limit = tonumber(args.limit) or 12
    local rows  = storage.get_spend_history("tenant", tenant_id, limit)
    for _, r in ipairs(rows) do r.amount_usd = r.amount_micro / 1e6 end
    send(200, rows)
end)

-- DELETE /admin/v1/gateways/:id/budget  — reset all (or ?period=) spend for a gateway
route("DELETE", "^/admin/v1/gateways/([^/]+)/budget$", function(gateway_id)
    if not require_gateway_access(gateway_id) then return end
    local args   = ngx.req.get_uri_args()
    local period = args.period ~= "" and args.period or nil
    storage.reset_spend("gateway", gateway_id, period)
    send(200, { ok = true })
end)

-- DELETE /admin/v1/tenants/:id/budget  — reset all (or ?period=) spend for a tenant
route("DELETE", "^/admin/v1/tenants/([^/]+)/budget$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local args   = ngx.req.get_uri_args()
    local period = args.period ~= "" and args.period or nil
    storage.reset_spend("tenant", tenant_id, period)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Organizations  (platform admin only for create/delete; own org for read/edit)
-- ---------------------------------------------------------------------------

route("GET", "^/admin/v1/organizations$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    send(200, storage.list_orgs())
end)

route("POST", "^/admin/v1/organizations$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local body = read_body()
    if not body.name or body.name == "" then return send(400, { error = "name required" }) end
    if not body.slug or body.slug == "" then return send(400, { error = "slug required" }) end
    local id = require("utils.uuid").v4()
    local err = storage.create_org(id, body.name, body.slug)
    if err then return send(409, { error = "slug already exists" }) end
    send(201, storage.get_org(id) or { id = id })
end)

route("GET", "^/admin/v1/organizations/([^/]+)$", function(org_id)
    if not auth.check_org(org_id) then return send(403, { error = "forbidden" }) end
    local org = storage.get_org(org_id)
    if not org then return send(404, { error = "not found" }) end
    send(200, org)
end)

route("PATCH", "^/admin/v1/organizations/([^/]+)$", function(org_id)
    if not auth.check_org(org_id) then return send(403, { error = "forbidden" }) end
    local body = read_body()
    local org  = storage.get_org(org_id)
    if not org then return send(404, { error = "not found" }) end
    storage.update_org(org_id, body.name or org.name, body.slug or org.slug)
    send(200, storage.get_org(org_id))
end)

route("DELETE", "^/admin/v1/organizations/([^/]+)$", function(org_id)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    storage.delete_org(org_id)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function M.handle()
    local method   = ngx.req.get_method()
    local path     = ngx.var.uri
    local actor_ip = ngx.var.remote_addr

    -- CORS preflight
    if method == "OPTIONS" then
        ngx.header["Access-Control-Allow-Origin"]      = cors_origin()
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        ngx.header["Access-Control-Allow-Headers"]     = "Content-Type, Authorization, x-aig-token"
        ngx.header["Access-Control-Max-Age"]           = "86400"
        ngx.status = 204
        ngx.exit(204)
        return
    end

    -- Authenticate the request if not already done by access_by_lua_block.
    -- (Docker nginx config omits the access phase; dev config includes it.)
    if not ngx.ctx.admin_user then
        require("admin.auth").require_session()
    end

    -- Audit log is written for every mutating request (POST/PATCH/DELETE).
    local function audit()
        if method ~= "GET" then
            local actor_id = ngx.ctx.admin_user and ngx.ctx.admin_user.id
            storage.insert_audit_log(actor_ip, method, path, ngx.status, actor_id)
        end
    end

    for _, r in ipairs(ROUTES) do
        if r.method == method then
            local captures = { path:match(r.pattern) }
            if #captures > 0 then
                r.handler(table.unpack(captures))
                audit()
                return
            end
        end
    end

    -- Handle routes with no captures (exact matches)
    for _, r in ipairs(ROUTES) do
        if r.method == method and path:match(r.pattern) then
            r.handler()
            audit()
            return
        end
    end

    send(404, { error = "not found" })
    audit()
end

return M
