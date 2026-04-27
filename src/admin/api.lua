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
--   GET    /admin/v1/gateways/:id/spend
--   DELETE /admin/v1/gateways/:id/budget
--   GET    /admin/v1/tenants/:id/spend
--   DELETE /admin/v1/tenants/:id/budget
--   GET    /admin/v1/tenants/:id/analytics
--   GET    /admin/v1/tenants/:id/keys
--   POST   /admin/v1/tenants/:id/keys
--   DELETE /admin/v1/tenants/:id/keys/:provider/:alias
--   GET    /admin/v1/tenants/:id/anthropic-usage
--   POST   /admin/v1/anthropic-usage/sync
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
--   GET    /admin/v1/projects
--   POST   /admin/v1/projects
--   GET    /admin/v1/projects/:id
--   PATCH  /admin/v1/projects/:id
--   DELETE /admin/v1/projects/:id
--   POST   /admin/v1/projects/:id/members
--   PATCH  /admin/v1/projects/:id/members/:uid
--   DELETE /admin/v1/projects/:id/members/:uid
--   GET    /admin/v1/projects/:id/knowledge
--   POST   /admin/v1/projects/:id/knowledge
--   DELETE /admin/v1/projects/:id/knowledge/:kid
--   GET    /admin/v1/projects/:id/knowledge-text
--   GET    /admin/v1/projects/:id/conversations

local json         = require("utils.json")
local storage      = require("storage")
local byok         = require("auth.byok")
local crypto       = require("utils.crypto")
local providers_mod    = require("providers")
local provider_health  = require("admin.provider_health")
local auth         = require("admin.auth")
local email        = require("utils.email")

local M = {}

local CORS_ORIGIN = os.getenv("AIG_ADMIN_CORS_ORIGIN")
-- Only emit CORS headers for explicitly configured origins.
-- Echoing the request Origin with Allow-Credentials: true would allow any
-- origin to make credentialed cross-origin requests.
local function cors_origin()
    return CORS_ORIGIN
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
-- Role assignment permission enforcement
-- ---------------------------------------------------------------------------

-- Roles each caller may assign.  A caller may not assign a role equal to or
-- above their own (except platform admins, who may assign anything).
local ASSIGNABLE_ROLES = {
    admin        = { admin=true, tenant_admin=true, member=true, viewer=true },
    tenant_admin = { member=true, viewer=true },
    member       = {},
    viewer       = {},
}

-- Returns an error string if the current admin user is not permitted to assign
-- target_role, or nil if the assignment is allowed.
local function validate_role_assignment(target_role)
    local u = ngx.ctx.admin_user
    local allowed = ASSIGNABLE_ROLES[u and u.role or ""] or {}
    if not allowed[target_role] then
        return "role '" .. tostring(target_role) ..
               "' cannot be assigned by a " .. tostring(u and u.role or "unknown")
    end
end

-- ---------------------------------------------------------------------------
-- Role helpers — enforce minimum role level for mutating operations
-- ---------------------------------------------------------------------------

-- Returns true if the current user is admin or tenant_admin.
-- Otherwise sends 403 and returns false.  Call at the top of any mutating
-- route that member/viewer must not reach.
local function require_tenant_admin()
    local u = ngx.ctx.admin_user
    if not u then send(401, { error = "unauthenticated" }); return false end
    if u.role ~= "admin" and u.role ~= "tenant_admin" then
        send(403, { error = "forbidden" })
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Ownership helpers — enforce tenant-scoped resource isolation
-- ---------------------------------------------------------------------------

-- Verifies tenant is accessible to the current user.
-- Returns tenant row, or sends 403/404 and returns nil.
local function require_tenant_access(tenant_id)
    local u = ngx.ctx.admin_user
    if not u then send(401, { error = "unauthenticated" }); return nil end
    local t = storage.get_tenant(tenant_id)
    if not t then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and u.tenant_id ~= tenant_id then
        send(403, { error = "forbidden" }); return nil
    end
    return t
end

-- Verifies gateway's owning tenant is accessible. Returns gateway row or nil.
local function require_gateway_access(gateway_id)
    local u = ngx.ctx.admin_user
    if not u then send(401, { error = "unauthenticated" }); return nil end
    local gw = storage.get_gateway_by_id(gateway_id)
    if not gw then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and u.tenant_id ~= gw.tenant_id then
        send(403, { error = "forbidden" }); return nil
    end
    return gw
end

-- Verifies user belongs to the same tenant as the caller. Returns user row or nil.
local function require_user_access(user_id)
    local u = ngx.ctx.admin_user
    if not u then send(401, { error = "unauthenticated" }); return nil end
    local usr = storage.get_user(user_id)
    if not usr then send(404, { error = "not found" }); return nil end
    if u.role ~= "admin" and usr.tenant_id ~= u.tenant_id then
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
    local u = ngx.ctx.admin_user
    if not u then return send(401, { error = "unauthenticated" }) end
    local args          = ngx.req.get_uri_args()
    local tenant_filter = (u.role ~= "admin") and u.tenant_id or args.tenant_id
    local user_filter   = (u.role == "member" or u.role == "viewer") and u.id or nil
    send(200, storage.get_usage_stats(tenant_filter, user_filter))
end)

-- GET /admin/v1/stats/timeseries?bucket=1h&n=24[&tenant_id=X]
-- bucket: 5m | 15m | 30m | 1h (default) | 6h | 1d
-- n: number of buckets to return (default 24, max 168)
local BUCKET_SIZES = { ["5m"]=300, ["15m"]=900, ["30m"]=1800, ["1h"]=3600, ["6h"]=21600, ["1d"]=86400 }
route("GET", "^/admin/v1/stats/timeseries$", function()
    local u = ngx.ctx.admin_user
    if not u then return send(401, { error = "unauthenticated" }) end
    local args       = ngx.req.get_uri_args()
    local bucket_sec = BUCKET_SIZES[args.bucket or "1h"] or 3600
    local n          = math.min(math.max(tonumber(args.n) or 24, 1), 168)
    local end_sec    = tonumber(args["until"])
    local tenant_id  = (u.role ~= "admin") and u.tenant_id
        or ((args.tenant_id ~= nil and args.tenant_id ~= "") and args.tenant_id or nil)
    local user_id    = (u.role == "member" or u.role == "viewer") and u.id or nil
    send(200, storage.get_stats_timeseries(bucket_sec, n, end_sec, tenant_id, user_id))
end)

route("GET", "^/admin/v1/logs$", function()
    if not require_tenant_admin() then return end
    local args = ngx.req.get_uri_args()
    local u = ngx.ctx.admin_user
    local tenant_filter = (u.role ~= "admin") and u.tenant_id or args.tenant_id
    send(200, storage.list_logs({
        tenant_id         = tenant_filter,
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

-- GET /admin/v1/stats/analytics?since=<unix_ms>[&until=<unix_ms>]
-- Returns latency percentiles (p50/p95/p99) and top models by request volume.
-- Optional `until` caps the upper bound (used for closed windows such as "yesterday").
route("GET", "^/admin/v1/stats/analytics$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and u.role ~= "tenant_admin" then return send(403, { error = "forbidden" }) end
    local args         = ngx.req.get_uri_args()
    local since        = tonumber(args.since)
    local until_ms     = tonumber(args["until"])
    local tenant_filter = (u.role ~= "admin") and u.tenant_id or args.tenant_id
    send(200, storage.get_analytics_depth(since, tenant_filter, until_ms))
end)

route("GET", "^/admin/v1/logs/([^/]+)$", function(id)
    if not require_tenant_admin() then return end
    local entry = storage.get_log(id)
    if not entry then return send(404, { error = "not found" }) end
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and entry.tenant_id ~= u.tenant_id then
        return send(403, { error = "forbidden" })
    end
    send(200, entry)
end)

-- ---------------------------------------------------------------------------
-- Tenant routes
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants$", function()
    local u = ngx.ctx.admin_user
    local tenant_filter = (u.role ~= "admin") and u.tenant_id or nil
    local rows = storage.list_tenants(tenant_filter)
    for _, r in ipairs(rows) do
        r.siem = r.siem_config and json.decode(r.siem_config) or nil
        r.siem_config = nil
        local cp, cp_err = r.chat_presets_config and json.decode(r.chat_presets_config) or nil
        if r.chat_presets_config and not cp then
            ngx.log(ngx.WARN, "tenant: corrupt chat_presets_config id=", r.id, " err=", tostring(cp_err))
        end
        r.chat_presets = cp or json.decode("[]")
        r.chat_presets_config = nil
        local sc, sc_err = r.slash_commands_config and json.decode(r.slash_commands_config) or nil
        if r.slash_commands_config and not sc then
            ngx.log(ngx.WARN, "tenant: corrupt slash_commands_config id=", r.id, " err=", tostring(sc_err))
        end
        r.slash_commands = sc or json.decode("[]")
        r.slash_commands_config = nil
    end
    send(200, rows)
end)

route("POST", "^/admin/v1/tenants$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then
        return send(403, { error = "forbidden" })
    end
    local b = read_body()
    if not b or not b.slug then return send(400, { error = "slug required" }) end
    local siem_json          = b.siem          and json.encode(b.siem)          or nil
    local chat_presets_json  = type(b.chat_presets) == "table" and json.encode(b.chat_presets) or nil
    local slash_commands_json = type(b.slash_commands) == "table" and json.encode(b.slash_commands) or nil
    local id = storage.upsert_tenant(b.slug, b.plan, b.budget_usd, b.budget_period, siem_json, chat_presets_json, slash_commands_json)
    send(201, { id = id, slug = b.slug })
end)

route("PATCH", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    if not require_tenant_admin() then return end
    if not require_tenant_access(tenant_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local siem_json           = (type(b.siem)           == "table") and json.encode(b.siem)           or nil
    local chat_presets_json   = (type(b.chat_presets)   == "table") and json.encode(b.chat_presets)   or nil
    local slash_commands_json = (type(b.slash_commands) == "table") and json.encode(b.slash_commands) or nil
    local err = storage.update_tenant(tenant_id, b.plan, nullable(b.budget_usd), b.budget_period, siem_json, chat_presets_json, slash_commands_json)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/tenants/([^/]+)$", function(tenant_id)
    if not require_tenant_admin() then return end
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
    if not require_tenant_admin() then return end
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
    if not require_tenant_admin() then return end
    local row = require_gateway_access(gateway_id)
    if not row then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local existing = json.decode(row.config or "{}") or {}
    if b.config then
        for k, v in pairs(b.config) do existing[k] = v end
    end
    local _, err = storage.upsert_gateway(row.tenant_id, row.slug, existing)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)$", function(gateway_id)
    if not require_tenant_admin() then return end
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
    if not require_tenant_admin() then return end
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
    if not require_tenant_admin() then return end
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
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local new_id = storage.upsert_routing_rule(gateway_id, nil,
        b.priority, b.conditions, b.actions, b.enabled)
    send(201, { id = new_id })
end)

route("PATCH", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(gateway_id, rule_id)
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    local err = storage.upsert_routing_rule(gateway_id, rule_id,
        b.priority, b.conditions, b.actions, b.enabled)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/rules/([^/]+)$", function(gateway_id, rule_id)
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local err = storage.delete_routing_rule(rule_id)
    if err then return send(500, { error = tostring(err) }) end
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
    local keys_list, keys_err = cfg_dict:get_keys(0)  -- 0 = no limit
    if not keys_list then
        ngx.log(ngx.WARN, "circuit_breaker status: get_keys failed gw=", gateway_id,
                " err=", tostring(keys_err))
        keys_list = {}
    end
    for _, k in ipairs(keys_list) do
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
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and u.role ~= "tenant_admin" then
        return send(403, { error = "forbidden" })
    end
    send(200, storage.list_model_prices())
end)

route("POST", "^/admin/v1/model%-prices/sync$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local args = ngx.req.get_uri_args()
    local model_sync = require("admin.model_sync")
    local results = model_sync.sync_all(args.provider)
    send(200, results)
end)

route("PUT", "^/admin/v1/model%-prices$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local b = read_body()
    if not b or not b.provider or not b.model then
        return send(400, { error = "provider and model required" })
    end
    local err = storage.upsert_model_price(b.provider, b.model,
        b.input_per_1k, b.output_per_1k, b.cache_write_per_1k, b.cache_read_per_1k, b.cache_write_1h_per_1k)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/model%-prices/([^/]+)/(.+)$", function(provider, model)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local err = storage.delete_model_price(provider, model)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- Model catalog — read-only, supports ?provider= filter
-- GET /admin/v1/models
-- GET /admin/v1/models?provider=openrouter
-- Returns model_price rows, augmented with computed capability flags:
--   supports_thinking: true for Anthropic claude-3-7-sonnet and all claude-4 / claude-*-4-* models
route("GET", "^/admin/v1/models$", function()
    local args     = ngx.req.get_uri_args()
    local provider = args.provider
    if provider == "" then provider = nil end
    local rows = storage.list_models(provider)
    for _, row in ipairs(rows) do
        local m = (row.model or ""):lower()
        -- claude-3-7-sonnet: first model with extended thinking
        -- claude-4 series: claude-4-*, claude-opus-4-*, claude-sonnet-4-*, claude-haiku-4-*
        -- azure_ai/ prefixed variants are excluded (not guaranteed to have thinking)
        local is_claude = m:match("^claude%-") or m:match("^azure_ai/claude%-")
        local is_thinking = is_claude and (
            m:match("^claude%-3%-7%-sonnet") or
            m:match("^claude%-4")            or
            m:match("^claude%-[a-z]+-4[-.]")  or
            m:match("^claude%-[a-z]+-4%d")    or
            m:match("^azure_ai/claude%-[a-z]+-4[-.]") or
            m:match("^azure_ai/claude%-4")
        )
        row.supports_thinking = is_thinking and true or false
    end
    send(200, rows)
end)

-- GET /admin/v1/providers
-- Returns provider metadata: name + whether an API key is required.
route("GET", "^/admin/v1/providers$", function()
    send(200, providers_mod.list())
end)

-- GET /admin/v1/providers/health
-- Returns all providers merged with configured status and live health from status-page polling.
route("GET", "^/admin/v1/providers/health$", function()
    local u = ngx.ctx.admin_user
    if not u then return send(401, { error = "unauthenticated" }) end

    local all_providers   = providers_mod.list()
    local configured_set  = storage.list_configured_providers()
    local health_rows     = storage.get_provider_health_all()
    local health_map      = {}
    for _, h in ipairs(health_rows) do
        health_map[h.provider] = h
    end

    local status_pages = provider_health.STATUS_PAGES
    local result = {}
    for _, p in ipairs(all_providers) do
        local h = health_map[p.name] or {}
        local configured
        if not p.requires_key then
            configured = json.null
        elseif configured_set[p.name] then
            configured = true
        else
            configured = false
        end
        result[#result + 1] = {
            name            = p.name,
            requires_key    = p.requires_key,
            configured      = configured,
            status          = h.status     or "unknown",
            message         = h.message,
            latency_ms      = h.latency_ms,
            checked_at      = (h.checked_at and h.checked_at ~= 0) and h.checked_at or json.null,
            has_status_page = (status_pages[p.name] ~= nil),
        }
    end
    send(200, result)
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

    local raw_token = "myra_" .. crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    -- 10-minute TTL — enough for a playground session
    local expires_ts = os.time() + 600
    local expires_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", expires_ts)

    local u = ngx.ctx.admin_user
    local _, err = storage.insert_auth_token(
        b.gateway_id, hash, {"playground"}, expires_ts,
        u and u.id, "playground", nil, nil)
    if err then return send(500, { error = tostring(err) }) end

    send(201, {
        token        = raw_token,
        expires_at   = expires_iso,
        tenant_slug  = gw.tenant_slug,
        gateway_slug = gw.gateway_slug,
    })
end)

-- GET /admin/v1/playground/search?q=...&gateway_id=...
-- Proxies a web search to Brave Search API and returns top organic results.
-- The Brave API key is read from the gateway's web_search.api_key configuration.
route("GET", "^/admin/v1/playground/search$", function()
    local args = ngx.req.get_uri_args()
    local q          = args.q
    local gateway_id = args.gateway_id
    if not q or q == "" then return send(400, { error = "q required" }) end
    if not gateway_id or gateway_id == "" then
        return send(400, { error = "gateway_id required" })
    end

    local gw = require_gateway_access(gateway_id)
    if not gw then return end  -- require_gateway_access already sent 403/404

    local gw_config  = json.decode(gw.config or "{}") or {}
    local ws_config  = gw_config.web_search
    local brave_key  = type(ws_config) == "table" and ws_config.api_key or nil
    if not brave_key or brave_key == "" then
        return send(503, {
            error = "web search not configured for this gateway "
                 .. "(set web_search.api_key in the gateway configuration)"
        })
    end

    local http = require("utils.http")
    local status, _, body, err = http.request({
        method  = "GET",
        url     = "https://api.search.brave.com/res/v1/web/search?q="
                  .. ngx.escape_uri(q) .. "&count=5",
        headers = {
            ["Accept"]               = "application/json",
            ["X-Subscription-Token"] = brave_key,
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
    if u.role ~= "admin" then
        if not t.gateway_id or not require_gateway_access(t.gateway_id) then return end
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
    if u.role ~= "admin" then
        if not t.gateway_id or not require_gateway_access(t.gateway_id) then return end
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
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local b = read_body()
    local raw_token = "myra_" .. crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b and b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(gateway_id, hash,
        b and b.scopes or {}, b and nullable(b.expires_at),
        b and nullable(b.user_id), b and nullable(b.label), rate_limit_json, b and nullable(b.budget_usd))
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, token = raw_token, gateway_id = gateway_id })
end)

route("DELETE", "^/admin/v1/gateways/([^/]+)/tokens/([^/]+)$", function(gateway_id, token_id)
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local err = storage.delete_auth_token(token_id, gateway_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- User routes
-- ---------------------------------------------------------------------------

-- Email allowlist for accounts that must never be soft-deleted, even by an
-- admin. Used by both DELETE /admin/v1/users/:id and DELETE /admin/v1/me.
local PROTECTED_EMAILS = {
    ["apple-review@myrasecurity.com"]  = true,
    ["google-review@myrasecurity.com"] = true,
    ["sascha@schumann.net"]            = true,
}

route("GET", "^/admin/v1/users$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    -- Returns users with no tenant (global admins). Pass ?include_deleted=1
    -- to also surface soft-deleted accounts so an admin can restore them.
    local args = ngx.req.get_uri_args()
    send(200, storage.list_users(false, {
        sort = args.sort, dir = args.dir,
        include_deleted = args.include_deleted == "1" or args.include_deleted == "true",
    }))
end)

route("GET", "^/admin/v1/tenants/([^/]+)/users$", function(tenant_id)
    if not require_tenant_admin() then return end
    if not auth.check_tenant(tenant_id) then return send(403, { error = "forbidden" }) end
    local args = ngx.req.get_uri_args()
    send(200, storage.list_users(tenant_id, {
        sort = args.sort, dir = args.dir,
        include_deleted = args.include_deleted == "1" or args.include_deleted == "true",
    }))
end)

route("POST", "^/admin/v1/tenants/([^/]+)/users$", function(tenant_id)
    if not require_tenant_admin() then return end
    if not auth.check_tenant(tenant_id) then return send(403, { error = "forbidden" }) end
    local b = read_body()
    if not b or not b.email then return send(400, { error = "email required" }) end
    local role = b.role or "member"
    local role_err = validate_role_assignment(role)
    if role_err then return send(403, { error = role_err }) end
    local id, err = storage.insert_user(tenant_id, b.email, nullable(b.name), role)
    if err then return send(500, { error = tostring(err) }) end

    -- Snapshot fields before timer so the closure doesn't capture the request-scoped table
    local inv_email = b.email
    local inv_name  = b.name
    local inv_role  = b.role or "member"
    ngx.timer.at(0, function()
        local mail_err = email.send_template(inv_email, "invitation", {
            name      = inv_name,
            email     = inv_email,
            role      = inv_role,
            login_url = os.getenv("AIG_FRONTEND_URL") or os.getenv("AIG_ADMIN_CORS_ORIGIN"),
        })
        if mail_err then
            ngx.log(ngx.WARN, "invitation email failed for ", inv_email, ": ", mail_err)
        end
    end)

    send(201, { id = id, email = b.email })
end)

route("POST", "^/admin/v1/users/([^/]+)/resend%-invite$", function(user_id)
    if not require_tenant_admin() then return end
    if not require_user_access(user_id) then return end
    local user = storage.get_user(user_id)
    if not user then return send(404, { error = "user not found" }) end
    -- Snapshot fields so the timer closure doesn't capture the request-scoped table
    local u_email = user.email
    local u_name  = user.name
    local u_role  = user.role
    ngx.timer.at(0, function()
        local mail_err = email.send_template(u_email, "invitation", {
            name      = u_name,
            email     = u_email,
            role      = u_role,
            login_url = os.getenv("AIG_FRONTEND_URL") or os.getenv("AIG_ADMIN_CORS_ORIGIN"),
        })
        if mail_err then
            ngx.log(ngx.WARN, "resend-invite email failed for ", u_email, ": ", mail_err)
        end
    end)
    send(200, { ok = true })
end)

-- User search (for project member invitations — any authenticated user)
route("GET", "^/admin/v1/users/search$", function()
    local args = ngx.req.get_uri_args()
    local email_arg = args.email
    if not email_arg or email_arg == "" then
        return send(400, { error = "email parameter required" })
    end
    local u = ngx.ctx.admin_user
    if not u.tenant_id then
        return send(400, { error = "user has no tenant" })
    end
    send(200, storage.search_users_by_email(u.tenant_id, email_arg))
end)

route("GET", "^/admin/v1/users/([^/]+)$", function(user_id)
    if not require_user_access(user_id) then return end
    local u = storage.get_user(user_id)
    if not u then return send(404, { error = "user not found" }) end
    send(200, u)
end)

route("PATCH", "^/admin/v1/users/([^/]+)$", function(user_id)
    if not require_tenant_admin() then return end
    local existing = require_user_access(user_id)
    if not existing then return end
    if existing.deleted_at then
        return send(409, { error = "Account is deleted; restore it before editing" })
    end
    local b = read_body()
    if not b then return send(400, { error = "invalid body" }) end
    if b.role then
        local role_err = validate_role_assignment(b.role)
        if role_err then return send(403, { error = role_err }) end
    end
    -- Use existing values for fields not included in the PATCH body
    local new_email = nullable(b.email) or existing.email
    local new_name  = (b.name  ~= nil) and nullable(b.name)  or existing.name
    local new_role  = b.role or existing.role
    -- tenant_id change is admin-only; non-admins may not reassign users to other tenants
    local new_tenant_id = nil
    if b.tenant_id ~= nil then
        local u = ngx.ctx.admin_user
        if u.role ~= "admin" then
            return send(403, { error = "only platform admins may change a user's tenant" })
        end
        local t = storage.get_tenant(b.tenant_id)
        if not t then return send(404, { error = "tenant not found" }) end
        new_tenant_id = b.tenant_id
    end
    local err = storage.update_user(user_id, new_email, new_name, new_role, new_tenant_id)
    if err then return send(500, { error = tostring(err) }) end
    local updated = storage.get_user(user_id)
    send(200, updated or { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)$", function(user_id)
    if not require_tenant_admin() then return end
    local existing = require_user_access(user_id)
    if not existing then return end
    if PROTECTED_EMAILS[existing.email] then
        return send(403, { error = "This account cannot be deleted" })
    end
    if existing.deleted_at then
        return send(200, { ok = true, already_deleted = true })
    end
    local me = ngx.ctx.admin_user
    local err = storage.delete_user(user_id, me.id)
    if err then return send(500, { error = tostring(err) }) end
    ngx.log(ngx.NOTICE, "user deleted (admin): id=", user_id,
            " email=", existing.email, " by=", me.id)
    send(200, { ok = true })
end)

-- POST /admin/v1/users/:id/restore — admin-initiated restore of a soft-deleted
-- (in-app "Delete Account") user. Clears deleted_at and the audit reference.
-- There is no self-service restore path; deleted users stay locked out until
-- an admin restores them.
route("POST", "^/admin/v1/users/([^/]+)/restore$", function(user_id)
    if not require_tenant_admin() then return end
    local existing = require_user_access(user_id)
    if not existing then return end
    if not existing.deleted_at then
        return send(200, { ok = true, already_active = true })
    end
    local err = storage.restore_user(user_id)
    if err then return send(500, { error = tostring(err) }) end
    local me = ngx.ctx.admin_user
    ngx.log(ngx.NOTICE, "user restored: id=", user_id,
            " email=", existing.email, " by=", me.id)
    send(200, { ok = true })
end)

-- PUT /admin/v1/users/:id/static-otp  — set a fixed static OTP code for a user
-- Body: {"code":"123456"}  — sets static code; {"code":null} — clears it (restores email OTP)
-- Admin-only. Returns {"ok":true,"code":"..."} when setting, {"ok":true} when clearing.
route("PUT", "^/admin/v1/users/([^/]+)/static%-otp$", function(user_id)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "admin only" }) end
    local b = read_body()
    local code = b and b.code
    local hash = nil
    if code ~= nil and code ~= json.null then
        code = tostring(code):match("^%s*(.-)%s*$")
        if #code < 4 or #code > 32 then
            return send(400, { error = "code must be 4–32 characters" })
        end
        hash = crypto.sha256_hex(code)
    end
    local err = storage.set_user_static_otp(user_id, hash)
    if err then return send(500, { error = tostring(err) }) end
    if hash then
        send(200, { ok = true, code = code })
    else
        send(200, { ok = true })
    end
end)

route("GET", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    if not require_user_access(user_id) then return end
    send(200, storage.list_user_tokens(user_id))
end)

route("POST", "^/admin/v1/users/([^/]+)/tokens$", function(user_id)
    if not require_tenant_admin() then return end
    if not require_user_access(user_id) then return end
    local b = read_body()
    if not b or not b.gateway_id then return send(400, { error = "gateway_id required" }) end
    if not require_gateway_access(b.gateway_id) then return end
    local raw_token = "myra_" .. crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(b.gateway_id, hash,
        b.scopes or {}, nullable(b.expires_at),
        user_id, nullable(b.label), rate_limit_json, nullable(b.budget_usd))
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, token = raw_token, gateway_id = b.gateway_id })
end)

-- ---------------------------------------------------------------------------
-- Self-service token management (any authenticated user)
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/me/tokens$", function()
    local me = ngx.ctx.admin_user
    send(200, storage.list_user_tokens(me.id))
end)

route("POST", "^/admin/v1/me/tokens$", function()
    local me = ngx.ctx.admin_user
    local b = read_body()
    if not b or not b.gateway_id then return send(400, { error = "gateway_id required" }) end
    if not require_gateway_access(b.gateway_id) then return end
    local raw_token = "myra_" .. crypto.random_hex(32)
    local hash      = crypto.sha256_hex(raw_token)
    local rate_limit_json = b.rate_limit and b.rate_limit ~= json.null and json.encode(b.rate_limit) or nil
    local id, err = storage.insert_auth_token(b.gateway_id, hash,
        b.scopes or {"inference"}, nullable(b.expires_at),
        me.id, nullable(b.label), rate_limit_json, nullable(b.budget_usd))
    if err then return send(500, { error = tostring(err) }) end
    send(201, { id = id, token = raw_token, gateway_id = b.gateway_id })
end)

route("DELETE", "^/admin/v1/me/tokens/([^/]+)$", function(token_id)
    local me = ngx.ctx.admin_user
    local tokens = storage.list_user_tokens(me.id)
    local owned = false
    for _, t in ipairs(tokens) do
        if t.id == token_id then owned = true; break end
    end
    if not owned then return send(403, { error = "forbidden" }) end
    local err = storage.delete_auth_token(token_id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- POST /admin/v1/me/device-token — register an APNs device token for push notifications
-- Body: {"token":"<hex-or-base64>","platform":"ios"}
route("POST", "^/admin/v1/me/device%-token$", function()
    local me = ngx.ctx.admin_user
    local b = read_body()
    if not b or not b.token or b.token == "" then
        return send(400, { error = "token required" })
    end
    local _, err = storage.upsert_device_token(me.id, b.token, b.platform or "ios")
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- DELETE /admin/v1/me/device-token — unregister device token on logout/uninstall
-- Body: {"token":"<token>"}
route("DELETE", "^/admin/v1/me/device%-token$", function()
    local me = ngx.ctx.admin_user
    local b = read_body()
    if not b or not b.token or b.token == "" then
        return send(400, { error = "token required" })
    end
    local err = storage.delete_device_token(b.token)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- DELETE /admin/v1/me — self-service account deletion (soft-delete).
-- Sets deleted_at on the authenticated user's account so the user is signed
-- out and locked out. Data is retained so an admin can restore the account
-- via POST /admin/v1/users/:id/restore. Reviewer accounts cannot be deleted.
route("DELETE", "^/admin/v1/me$", function()
    local me = ngx.ctx.admin_user
    if PROTECTED_EMAILS[me.email] then
        return send(403, { error = "This account cannot be deleted" })
    end
    local err = storage.delete_user(me.id, me.id)
    if err then return send(500, { error = tostring(err) }) end
    ngx.log(ngx.NOTICE, "user deleted (self): id=", me.id, " email=", me.email)
    send(200, { ok = true })
end)

route("DELETE", "^/admin/v1/users/([^/]+)/budget$", function(user_id)
    if not require_tenant_admin() then return end
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

-- ---------------------------------------------------------------------------
-- Application feedback (AGF-31) — bug reports, feature suggestions
-- ---------------------------------------------------------------------------

-- POST /admin/v1/app-feedback  — submit application feedback (any authenticated user)
route("POST", "^/admin/v1/app%-feedback$", function()
    local u    = ngx.ctx.admin_user
    local b    = read_body()
    if not b or not b.summary or tostring(b.summary):match("^%s*$") then
        return send(400, { error = "summary required" })
    end
    local t = tostring(b.type or "other")
    if t ~= "bug" and t ~= "feature" and t ~= "other" then t = "other" end
    local entry = {
        id          = require("utils.uuid").v4(),
        user_id     = u.id,
        type        = t,
        summary     = tostring(b.summary):sub(1, 255),
        description = b.description and tostring(b.description):sub(1, 4000) or nil,
        url         = b.url and tostring(b.url):sub(1, 1024) or nil,
    }
    local id, err = storage.insert_app_feedback(entry)
    if not id then return send(500, { error = err or "db error" }) end
    send(201, { id = id })
end)

-- GET /admin/v1/app-feedback?limit=50&offset=0&type=bug  — admin-only list
route("GET", "^/admin/v1/app%-feedback$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local args = ngx.req.get_uri_args()
    send(200, storage.list_app_feedback(
        tonumber(args.limit) or 50,
        tonumber(args.offset) or 0,
        args.type
    ))
end)

-- PATCH /admin/v1/app-feedback/:id  — admin-only, mark as processed
route("PATCH", "^/admin/v1/app%-feedback/([^/]+)$", function(id)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" then return send(403, { error = "forbidden" }) end
    local b   = read_body()
    local err = storage.update_app_feedback(id, b.processed ~= false and b.processed ~= 0)
    if err then return send(500, { error = err }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Content reports — users flagging inappropriate / inaccurate AI output.
-- Required by Google Play's generative-AI policy (effective Jan 28 2026).
-- ---------------------------------------------------------------------------

-- POST /admin/v1/reports — any authenticated user may file a report.
-- Body: { reason, conversation_id?, message_id?, message_text?, notes? }
route("POST", "^/admin/v1/reports$", function()
    local u = ngx.ctx.admin_user
    local b = read_body()
    if not b or not b.reason then
        return send(400, { error = "reason required" })
    end
    if not storage.is_valid_content_report_reason(b.reason) then
        return send(400, { error = "invalid reason" })
    end
    local report = {
        user_id         = u.id,
        tenant_id       = u.tenant_id,
        conversation_id = b.conversation_id and tostring(b.conversation_id) or nil,
        message_id      = b.message_id and tostring(b.message_id) or nil,
        message_text    = b.message_text and tostring(b.message_text):sub(1, 16000) or nil,
        reason          = b.reason,
        notes           = b.notes and tostring(b.notes):sub(1, 2000) or nil,
    }
    local id, err = storage.insert_content_report(report)
    if not id then return send(500, { error = err or "db error" }) end
    ngx.log(ngx.NOTICE, "content report filed: id=", id, " by=", u.id,
            " tenant=", tostring(u.tenant_id), " reason=", b.reason)
    send(201, { id = id })
end)

-- GET /admin/v1/reports?status=open&limit=100&offset=0
-- Admin sees all tenants; tenant_admin sees only their tenant.
route("GET", "^/admin/v1/reports$", function()
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and u.role ~= "tenant_admin" then
        return send(403, { error = "forbidden" })
    end
    local args = ngx.req.get_uri_args()
    local opts = {
        status = args.status,
        limit  = tonumber(args.limit),
        offset = tonumber(args.offset),
    }
    if u.role == "tenant_admin" then opts.tenant_id = u.tenant_id end
    send(200, storage.list_content_reports(opts))
end)

-- PATCH /admin/v1/reports/:id  — { status: "triaged" | "dismissed" | "open" }
route("PATCH", "^/admin/v1/reports/([^/]+)$", function(id)
    local u = ngx.ctx.admin_user
    if u.role ~= "admin" and u.role ~= "tenant_admin" then
        return send(403, { error = "forbidden" })
    end
    local existing = storage.get_content_report(id)
    if not existing then return send(404, { error = "report not found" }) end
    if u.role == "tenant_admin" and existing.tenant_id ~= u.tenant_id then
        return send(403, { error = "forbidden" })
    end
    local b = read_body()
    local status = b and b.status
    if status ~= "open" and status ~= "triaged" and status ~= "dismissed" then
        return send(400, { error = "invalid status" })
    end
    local err = storage.update_content_report_status(id, status, u.id)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
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
    for _, r in ipairs(rows) do r.amount_usd = (r.amount_micro or 0) / 1e6 end
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
    for _, r in ipairs(rows) do r.amount_usd = (r.amount_micro or 0) / 1e6 end
    send(200, rows)
end)

-- DELETE /admin/v1/gateways/:id/budget  — reset all (or ?period=) spend for a gateway
route("DELETE", "^/admin/v1/gateways/([^/]+)/budget$", function(gateway_id)
    if not require_tenant_admin() then return end
    if not require_gateway_access(gateway_id) then return end
    local args   = ngx.req.get_uri_args()
    local period = args.period ~= "" and args.period or nil
    storage.reset_spend("gateway", gateway_id, period)
    send(200, { ok = true })
end)

-- DELETE /admin/v1/tenants/:id/budget  — reset all (or ?period=) spend for a tenant
route("DELETE", "^/admin/v1/tenants/([^/]+)/budget$", function(tenant_id)
    if not require_tenant_admin() then return end
    if not require_tenant_access(tenant_id) then return end
    local args   = ngx.req.get_uri_args()
    local period = args.period ~= "" and args.period or nil
    storage.reset_spend("tenant", tenant_id, period)
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Tenant-scoped provider key routes (e.g. anthropic-admin key)
-- ---------------------------------------------------------------------------
route("GET", "^/admin/v1/tenants/([^/]+)/keys$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    send(200, storage.list_tenant_provider_configs(tenant_id))
end)

route("POST", "^/admin/v1/tenants/([^/]+)/keys$", function(tenant_id)
    if not require_tenant_admin() then return end
    if not require_tenant_access(tenant_id) then return end
    local b = read_body()
    if not b or not b.provider or not b.key then
        return send(400, { error = "provider and key required" })
    end
    local err = byok.store_tenant_key(tenant_id, b.provider, b.alias or "default", b.key)
    if err then return send(500, { error = tostring(err) }) end
    send(201, { ok = true, provider = b.provider, alias = b.alias or "default" })
end)

route("DELETE", "^/admin/v1/tenants/([^/]+)/keys/([^/]+)/([^/]+)$", function(tenant_id, provider, alias)
    if not require_tenant_admin() then return end
    if not require_tenant_access(tenant_id) then return end
    local err = storage.delete_tenant_provider_config(tenant_id, provider, alias)
    if err then return send(500, { error = tostring(err) }) end
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- Anthropic usage routes
-- ---------------------------------------------------------------------------

-- GET /admin/v1/tenants/:id/anthropic-usage?from=YYYY-MM-DD&to=YYYY-MM-DD
route("GET", "^/admin/v1/tenants/([^/]+)/anthropic%-usage$", function(tenant_id)
    if not require_tenant_access(tenant_id) then return end
    local args     = ngx.req.get_uri_args()
    local from_d   = (args.from ~= "" and args.from) or os.date("!%Y-%m-%d", os.time() - 30 * 86400)
    local to_d     = (args.to   ~= "" and args.to)   or os.date("!%Y-%m-%d", os.time())
    local rows     = storage.get_anthropic_usage(tenant_id, from_d, to_d)
    local totals   = { uncached_input_tokens = 0, output_tokens = 0,
                       cache_write_5m_tokens = 0, cache_write_1h_tokens = 0,
                       cache_read_tokens = 0, web_search_requests = 0, cost_usd = "0" }
    local last_syn = nil
    local total_cost = 0
    for _, r in ipairs(rows) do
        totals.uncached_input_tokens = totals.uncached_input_tokens + (r.uncached_input_tokens or 0)
        totals.output_tokens         = totals.output_tokens         + (r.output_tokens         or 0)
        totals.cache_write_5m_tokens = totals.cache_write_5m_tokens + (r.cache_write_5m_tokens or 0)
        totals.cache_write_1h_tokens = totals.cache_write_1h_tokens + (r.cache_write_1h_tokens or 0)
        totals.cache_read_tokens     = totals.cache_read_tokens     + (r.cache_read_tokens     or 0)
        totals.web_search_requests   = totals.web_search_requests   + (r.web_search_requests   or 0)
        total_cost = total_cost + tonumber(r.cost_usd or "0")
        if r.fetched_at and (not last_syn or r.fetched_at > last_syn) then
            last_syn = r.fetched_at
        end
    end
    totals.cost_usd = string.format("%.8f", total_cost)
    send(200, { daily = rows, totals = totals, last_synced_at = last_syn })
end)

-- POST /admin/v1/anthropic-usage/sync  — manual trigger (admin only)
route("POST", "^/admin/v1/anthropic%-usage/sync$", function()
    if not require_tenant_admin() then return end
    ngx.timer.at(0, function(premature)
        if premature then return end
        local ok, err = pcall(require("admin.anthropic_usage_sync").sync_recent)
        if not ok then
            ngx.log(ngx.ERR, "anthropic_usage_sync: manual trigger failed: ", tostring(err))
        end
    end)
    send(200, { ok = true, message = "sync triggered" })
end)

-- ---------------------------------------------------------------------------
-- Chat routes (conversations, messages, attachments, presets)
-- ---------------------------------------------------------------------------
require("admin.chat").register(route)

-- ---------------------------------------------------------------------------
-- Project routes (projects, members, knowledge)
-- ---------------------------------------------------------------------------
require("admin.projects").register(route)

-- ---------------------------------------------------------------------------
-- MCP connector routes
-- ---------------------------------------------------------------------------
require("admin.mcp").register(route)

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
