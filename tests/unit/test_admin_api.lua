-- tests/unit/test_admin_api.lua — unit tests for admin/api.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_api.lua

-- ---------------------------------------------------------------------------
-- Minimal ngx stub
-- ---------------------------------------------------------------------------
local response_body   = nil
local response_status = 200

local _prev_e64 = _G.ngx and _G.ngx.encode_base64
local _prev_d64 = _G.ngx and _G.ngx.decode_base64

_G.ngx = {
    now           = function() return 1700000000.0 end,
    time          = function() return 1700000000 end,
    log           = function() end,
    encode_base64 = _prev_e64,
    decode_base64 = _prev_d64,
    -- ngx.exit called by OPTIONS handler; we capture and continue
    exit   = function(code) response_status = code end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
        get_method    = function() return "GET" end,
        get_uri_args  = function() return {} end,
    },
    var    = { uri = "/", remote_addr = "127.0.0.1" },
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    print  = function(s) response_body = s end,
    escape_uri = function(s) return s end,
    timer  = { at = function() end },
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local cjson = require("cjson.safe")

local pass, fail = 0, 0

local function ok(name, cond, msg)
    if cond then
        pass = pass + 1
        print("PASS  " .. name)
    else
        fail = fail + 1
        print("FAIL  " .. name .. (msg and (" — " .. tostring(msg)) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- Storage stub (comprehensive, all methods stubbed with sensible defaults)
-- ---------------------------------------------------------------------------
local audit_log_calls = {}
local storage_calls   = {}

local function track(name, ...)
    storage_calls[#storage_calls + 1] = { name = name, args = {...} }
end

local gateways_db = {
    ["gw-1"] = { id = "gw-1", slug = "main", tenant_id = "tn-1",
                 config = cjson.encode({ log_payloads = false,
                     web_search = { enabled = true, api_key = "test-brave-key" } }) },
}
local tenants_db = {
    ["tn-1"] = { id = "tn-1", slug = "acme", plan = "pro", siem_config = nil },
}

local storage_stub = {
    get_usage_stats           = function(tenant_id)   track("get_usage_stats", tenant_id); return { requests = 10 } end,
    get_stats_timeseries      = function(...)          track("get_stats_timeseries", ...); return {} end,
    list_logs                 = function(filter)       track("list_logs", filter); return {} end,
    get_analytics_depth       = function(since)        track("get_analytics_depth", since); return {} end,
    get_log                   = function(id)
        track("get_log", id)
        if id == "log-found" then return { id = id, model = "gpt-4o" } end
        return nil
    end,
    get_tenant                = function(id)           track("get_tenant", id)
        return { id = id, slug = "acme" }
    end,
    list_tenants              = function()             track("list_tenants"); return {
        { id = "tn-1", slug = "acme", siem_config = cjson.encode({ host = "siem.example.com" }) },
        { id = "tn-2", slug = "beta", siem_config = nil },
    } end,
    upsert_tenant             = function(slug, ...)   track("upsert_tenant", slug); return "tn-new" end,
    update_tenant             = function(id, ...)     track("update_tenant", id); return nil end,
    delete_tenant             = function(id)          track("delete_tenant", id); return nil end,
    list_gateways             = function(tenant_id)   track("list_gateways", tenant_id)
        return { { id = "gw-1", slug = "main", config = "{}" } }
    end,
    upsert_gateway            = function(tid, slug, cfg)
        track("upsert_gateway", tid, slug)
        return "gw-new"
    end,
    get_gateway_by_id         = function(id)
        track("get_gateway_by_id", id)
        local r = gateways_db[id]
        if not r then return nil end
        -- Return a shallow copy so route handlers that mutate row.config
        -- (e.g. GET /gateways/:id decodes config in-place) don't affect the fixture.
        return { id = r.id, slug = r.slug, tenant_id = r.tenant_id, config = r.config }
    end,
    delete_gateway            = function(id)          track("delete_gateway", id); return nil end,
    list_provider_configs     = function(gw_id)       track("list_provider_configs", gw_id); return {} end,
    list_routing_rules        = function(gw_id)       track("list_routing_rules", gw_id)
        return { { id = "rule-1", conditions = "[]", actions = "{}", priority = 1, enabled = 1 } }
    end,
    upsert_routing_rule       = function(gw_id, rule_id, ...)
        track("upsert_routing_rule")
        -- nil rule_id = INSERT (return new id); non-nil = UPDATE (return nil = no error)
        return rule_id == nil and "rule-new" or nil
    end,
    delete_routing_rule       = function(id)          track("delete_routing_rule", id) end,
    get_gateway_guardrail_stats = function(gw_id)     track("get_gateway_guardrail_stats", gw_id); return {} end,
    list_guardrail_events     = function(gw_id, lim)  track("list_guardrail_events", gw_id, lim); return {} end,
    list_model_prices         = function()             track("list_model_prices"); return {} end,
    upsert_model_price        = function(...)          track("upsert_model_price"); return nil end,
    delete_model_price        = function(p, m)        track("delete_model_price", p, m) end,
    list_models               = function(prov)        track("list_models", prov); return {} end,
    list_auth_tokens          = function(gw_id)       track("list_auth_tokens", gw_id); return {} end,
    insert_auth_token         = function(...)          track("insert_auth_token"); return "tok-new", nil end,
    delete_auth_token         = function(id)          track("delete_auth_token", id) end,
    delete_expired_playground_tokens = function(gw_id) track("delete_expired_playground_tokens", gw_id) end,
    get_gateway_with_tenant_slug = function(gw_id)
        track("get_gateway_with_tenant_slug", gw_id)
        if gw_id == "gw-1" then
            return { id = "gw-1", tenant_slug = "acme", gateway_slug = "main" }
        end
        return nil
    end,
    get_user                  = function(id)           track("get_user", id)
        return { id = id, email = "user@example.com", role = "member", tenant_id = "tn-1" }
    end,
    list_users                = function(tenant_id)   track("list_users", tenant_id); return {} end,
    insert_user               = function(tid, email, name, role)
        track("insert_user", tid, email)
        return "user-new", nil
    end,
    update_user               = function(id, ...)    track("update_user", id); return nil end,
    delete_user               = function(id)         track("delete_user", id); return nil end,
    list_user_tokens          = function(uid)        track("list_user_tokens", uid); return {} end,
    list_user_gateways        = function(uid)        track("list_user_gateways", uid); return {} end,
    set_user_gateway_access   = function(uid, gw_id) track("set_user_gateway_access", uid, gw_id); return nil end,
    delete_user_gateway_access = function(uid, gw_id) track("delete_user_gateway_access", uid, gw_id); return nil end,
    reset_spend               = function(et, id, p)  track("reset_spend", et, id, p) end,
    get_spend_history         = function(et, id, lim) track("get_spend_history", et, id, lim)
        return { { period = "2026-03", amount_micro = 500000 } }
    end,
    get_tenant_top_models     = function(tid, since) track("get_tenant_top_models", tid, since); return {} end,
    insert_client_error       = function(...)        track("insert_client_error"); return nil end,
    list_client_errors        = function(lim)        track("list_client_errors", lim); return {} end,
    list_audit_logs           = function(lim, off)   track("list_audit_logs", lim, off); return {} end,
    insert_audit_log          = function(ip, method, path, status)
        audit_log_calls[#audit_log_calls + 1] = { ip = ip, method = method, path = path, status = status }
    end,
    list_gateway_traces       = function(gw_id, lim) track("list_gateway_traces", gw_id, lim); return {} end,
    get_playground_trace      = function(id)         track("get_playground_trace", id); return nil end,
    get_playground_trace_steps = function(id)        return {} end,
    search_users_by_email     = function(tid, email) track("search_users_by_email", tid, email)
        return { { id = "found-uid", email = email, role = "member", tenant_id = tid } }
    end,
    list_tenant_provider_configs = function(tid)     track("list_tenant_provider_configs", tid); return {} end,
    anthropic_usage_list         = function(tid)     track("anthropic_usage_list", tid); return {} end,
}

-- ---------------------------------------------------------------------------
-- HTTP stub for playground/search
-- ---------------------------------------------------------------------------
local http_stub_response = { status = 200, body = cjson.encode({
    web = { results = {
        { title = "Lua Guide", url = "https://lua.org", description = "Lua programming" }
    }}
}) }
local http_stub = {
    request = function(opts)
        return http_stub_response.status, {}, http_stub_response.body, http_stub_response.err
    end,
}

-- ---------------------------------------------------------------------------
-- Load admin/api once with all stubs pre-loaded
-- ---------------------------------------------------------------------------
local MODULES = {
    "admin.api", "storage", "auth.byok", "utils.crypto",
    "utils.json", "providers", "core.app_config", "utils.uuid",
    "utils.http",
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
    return {
        random_hex = function(n) return string.rep("a", n * 2) end,
        sha256_hex = function(s) return "HASH:" .. s end,
    }
end
package.preload["auth.byok"]   = function()
    return { store_key = function(gw_id, prov, alias, key) return nil end }
end
package.preload["providers"]   = function()
    return { list = function() return { { name = "openai" } } end }
end
package.preload["core.app_config"] = function()
    return { get = function() return {} end, shared_dict = { rate_limit = "rl", config = "cfg" } }
end
package.preload["utils.uuid"]  = function()
    local n = 0
    return { v4 = function() n = n+1; return "uuid-"..n end }
end
package.loaded["utils.http"]   = http_stub

local api = require("admin.api")

-- ---------------------------------------------------------------------------
-- Helper: set up a request and call handle(), return decoded response
-- ---------------------------------------------------------------------------
local function call(method, uri, body_tbl, query_args, user_override)
    response_body   = nil
    response_status = 200
    ngx.status      = 200
    audit_log_calls = {}

    ngx.ctx.admin_user = user_override or { id = "user-1", role = "admin", tenant_id = "tn-1" }
    ngx.req.get_method   = function() return method end
    ngx.req.get_uri_args = function() return query_args or {} end
    ngx.var.uri          = uri

    if body_tbl ~= nil then
        local encoded = cjson.encode(body_tbl)
        ngx.req.get_body_data = function() return encoded end
    else
        ngx.req.get_body_data = function() return nil end
    end

    api.handle()

    -- ngx.status may be written directly by send(); capture it
    local status = ngx.status ~= 200 and ngx.status or response_status
    -- Also check if response_status was updated (e.g. ngx.exit(204))
    if response_status ~= 200 and response_status ~= status then
        status = response_status
    end
    local decoded = response_body and (cjson.decode(response_body) or {}) or {}
    return status, decoded
end

-- ---------------------------------------------------------------------------
-- Stats & logs
-- ---------------------------------------------------------------------------
local s, b = call("GET", "/admin/v1/stats")
ok("GET /stats → 200", ngx.status == 200, ngx.status)
ok("GET /stats → has requests field", b.requests ~= nil)

s, b = call("GET", "/admin/v1/stats/timeseries", nil, { bucket = "1h", n = "24" })
ok("GET /stats/timeseries → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/stats/analytics", nil, { since = "1700000000000" })
ok("GET /stats/analytics → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/logs")
ok("GET /logs → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/logs/log-found")
ok("GET /logs/:id found → 200", ngx.status == 200, ngx.status)
ok("GET /logs/:id → correct id", b.id == "log-found", b.id)

s, b = call("GET", "/admin/v1/logs/log-missing")
ok("GET /logs/:id not found → 404", ngx.status == 404, ngx.status)

-- ---------------------------------------------------------------------------
-- Tenants
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/tenants")
ok("GET /tenants → 200", ngx.status == 200)
ok("GET /tenants → siem_config decoded to siem field",
    type(b[1]) == "table" and type(b[1].siem) == "table",
    type(b[1] and b[1].siem))
ok("GET /tenants → siem_config field removed",
    b[1].siem_config == nil)
ok("GET /tenants → nil siem_config becomes nil siem",
    b[2].siem == nil)

s, b = call("POST", "/admin/v1/tenants", { slug = "newco", plan = "free" })
ok("POST /tenants valid → 201", ngx.status == 201, ngx.status)
ok("POST /tenants → id returned", b.id ~= nil)

s, b = call("POST", "/admin/v1/tenants", { plan = "free" })  -- no slug
ok("POST /tenants no slug → 400", ngx.status == 400, ngx.status)
ok("POST /tenants no slug → error msg", b.error ~= nil)

s, b = call("PATCH", "/admin/v1/tenants/tn-1", { plan = "enterprise" })
ok("PATCH /tenants/:id → 200", ngx.status == 200)

s, b = call("DELETE", "/admin/v1/tenants/tn-1")
ok("DELETE /tenants/:id → 200", ngx.status == 200)

-- Audit log written for mutating requests
ok("PATCH /tenants audit log written", #audit_log_calls == 1)

-- ---------------------------------------------------------------------------
-- Gateways
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/tenants/tn-1/gateways")
ok("GET /tenants/:id/gateways → 200", ngx.status == 200)

s, b = call("POST", "/admin/v1/tenants/tn-1/gateways", { slug = "api" })
ok("POST /tenants/:id/gateways valid → 201", ngx.status == 201)

s, b = call("POST", "/admin/v1/tenants/tn-1/gateways", { config = {} }) -- no slug
ok("POST /tenants/:id/gateways no slug → 400", ngx.status == 400)

s, b = call("GET", "/admin/v1/gateways/gw-1")
ok("GET /gateways/:id found → 200", ngx.status == 200)
ok("GET /gateways/:id → config decoded", type(b.config) == "table")

s, b = call("GET", "/admin/v1/gateways/gw-notfound")
ok("GET /gateways/:id not found → 404", ngx.status == 404)

s, b = call("PATCH", "/admin/v1/gateways/gw-1", { config = { model = "gpt-4o" } })
ok("PATCH /gateways/:id found → 200", ngx.status == 200)

s, b = call("PATCH", "/admin/v1/gateways/gw-notfound", { config = {} })
ok("PATCH /gateways/:id not found → 404", ngx.status == 404)

s, b = call("DELETE", "/admin/v1/gateways/gw-1")
ok("DELETE /gateways/:id → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- BYOK keys
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/keys")
ok("GET /gateways/:id/keys → 200", ngx.status == 200)

s, b = call("POST", "/admin/v1/gateways/gw-1/keys",
    { provider = "openai", key = "sk-test" })
ok("POST /gateways/:id/keys valid → 201", ngx.status == 201)
ok("POST /gateways/:id/keys → provider in response", b.provider == "openai")

s, b = call("POST", "/admin/v1/gateways/gw-1/keys", { provider = "openai" }) -- no key
ok("POST /gateways/:id/keys missing key → 400", ngx.status == 400)

-- ---------------------------------------------------------------------------
-- Routing rules
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/rules")
ok("GET /gateways/:id/rules → 200", ngx.status == 200)
ok("GET /gateways/:id/rules → conditions decoded", type(b[1].conditions) == "table")

s, b = call("POST", "/admin/v1/gateways/gw-1/rules",
    { priority = 10, conditions = {}, actions = {}, enabled = true })
ok("POST /gateways/:id/rules → 201", ngx.status == 201)
ok("POST /gateways/:id/rules → id returned", b.id ~= nil)

s, b = call("PATCH", "/admin/v1/gateways/gw-1/rules/rule-1",
    { priority = 5, enabled = false })
ok("PATCH /gateways/:id/rules/:id → 200", ngx.status == 200)

s, b = call("DELETE", "/admin/v1/gateways/gw-1/rules/rule-1")
ok("DELETE /gateways/:id/rules/:id → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Guardrail stats & events
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/guardrail-stats")
ok("GET /gateways/:id/guardrail-stats → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/gateways/gw-1/guardrail-events")
ok("GET /gateways/:id/guardrail-events → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/tokens")
ok("GET /gateways/:id/tokens → 200", ngx.status == 200)

s, b = call("POST", "/admin/v1/gateways/gw-1/tokens",
    { label = "ci-bot", scopes = {} })
ok("POST /gateways/:id/tokens → 201", ngx.status == 201)
ok("POST /gateways/:id/tokens → token returned", b.token ~= nil)

s, b = call("DELETE", "/admin/v1/gateways/gw-1/tokens/tok-abc")
ok("DELETE /gateways/:id/tokens/:tid → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/tenants/tn-1/users")
ok("GET /tenants/:id/users → 200", ngx.status == 200)

s, b = call("POST", "/admin/v1/tenants/tn-1/users",
    { email = "bob@example.com", role = "member" })
ok("POST /tenants/:id/users valid → 201", ngx.status == 201)
ok("POST /tenants/:id/users → id returned", b.id ~= nil)

s, b = call("POST", "/admin/v1/tenants/tn-1/users", { name = "Bob" }) -- no email
ok("POST /tenants/:id/users no email → 400", ngx.status == 400)

s, b = call("PATCH", "/admin/v1/users/user-1", { name = "Robert" })
ok("PATCH /users/:id → 200", ngx.status == 200)

s, b = call("DELETE", "/admin/v1/users/user-1")
ok("DELETE /users/:id → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/users/user-1/tokens")
ok("GET /users/:id/tokens → 200", ngx.status == 200)

s, b = call("POST", "/admin/v1/users/user-1/tokens",
    { gateway_id = "gw-1", label = "laptop" })
ok("POST /users/:id/tokens valid → 201", ngx.status == 201)
ok("POST /users/:id/tokens → token returned", b.token ~= nil)

s, b = call("POST", "/admin/v1/users/user-1/tokens", { label = "x" }) -- no gateway_id
ok("POST /users/:id/tokens no gateway_id → 400", ngx.status == 400)

s, b = call("DELETE", "/admin/v1/users/user-1/budget")
ok("DELETE /users/:id/budget → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Budget & spend
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/spend")
ok("GET /gateways/:id/spend → 200", ngx.status == 200)
ok("GET /gateways/:id/spend → amount_usd computed",
    b[1] and b[1].amount_usd == 0.5,
    b[1] and b[1].amount_usd)

s, b = call("GET", "/admin/v1/tenants/tn-1/spend")
ok("GET /tenants/:id/spend → 200", ngx.status == 200)

s, b = call("DELETE", "/admin/v1/gateways/gw-1/budget")
ok("DELETE /gateways/:id/budget → 200", ngx.status == 200)

s, b = call("DELETE", "/admin/v1/tenants/tn-1/budget")
ok("DELETE /tenants/:id/budget → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/tenants/tn-1/analytics", nil, { since = "0" })
ok("GET /tenants/:id/analytics → 200", ngx.status == 200)
ok("GET /tenants/:id/analytics → has timeseries", b.timeseries ~= nil)

-- ---------------------------------------------------------------------------
-- Models & providers
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/models")
ok("GET /models → 200", ngx.status == 200)

s, b = call("GET", "/admin/v1/providers")
ok("GET /providers → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Playground
-- ---------------------------------------------------------------------------
s, b = call("POST", "/admin/v1/playground/token", { gateway_id = "gw-1" })
ok("POST /playground/token valid → 201", ngx.status == 201, ngx.status)
ok("POST /playground/token → token returned", b.token ~= nil)
ok("POST /playground/token → tenant_slug", b.tenant_slug == "acme")

s, b = call("POST", "/admin/v1/playground/token", { model = "gpt-4o" }) -- no gateway_id
ok("POST /playground/token no gateway_id → 400", ngx.status == 400)

s, b = call("POST", "/admin/v1/playground/token", { gateway_id = "gw-notfound" })
ok("POST /playground/token gateway not found → 404", ngx.status == 404, ngx.status)

s, b = call("GET", "/admin/v1/playground/search", nil, { q = "lua programming", gateway_id = "gw-1" })
ok("GET /playground/search valid → 200", ngx.status == 200, ngx.status)
ok("GET /playground/search → results array", type(b.results) == "table")
ok("GET /playground/search → query echoed", b.query == "lua programming")

s, b = call("GET", "/admin/v1/playground/search", nil, {}) -- no q
ok("GET /playground/search no q → 400", ngx.status == 400)

-- HTTP error from search API
local saved = http_stub.request
http_stub.request = function(opts) return 200, {}, nil, "connection refused" end
s, b = call("GET", "/admin/v1/playground/search", nil, { q = "test", gateway_id = "gw-1" })
ok("GET /playground/search http error → 502", ngx.status == 502)
http_stub.request = saved

-- HTTP non-200 from search API
http_stub.request = function(opts) return 503, {}, nil, nil end
s, b = call("GET", "/admin/v1/playground/search", nil, { q = "test", gateway_id = "gw-1" })
ok("GET /playground/search non-200 → 502", ngx.status == 502)
http_stub.request = saved

s, b = call("GET", "/admin/v1/playground/trace/trace-notfound")
ok("GET /playground/trace/:id not found → 404", ngx.status == 404)

storage_stub.get_playground_trace = function(id)
    return { id = id, request_id = "req-1" }
end
s, b = call("GET", "/admin/v1/playground/trace/trace-found")
ok("GET /playground/trace/:id found → 200", ngx.status == 200)
ok("GET /playground/trace/:id → trace present", b.trace ~= nil)
storage_stub.get_playground_trace = function(id) return nil end

-- ---------------------------------------------------------------------------
-- Client errors
-- ---------------------------------------------------------------------------
s, b = call("POST", "/admin/v1/client-errors",
    { message = "TypeError: cannot read undefined", url = "https://app.example.com" })
ok("POST /client-errors valid → 201", ngx.status == 201)

s, b = call("POST", "/admin/v1/client-errors", { url = "x" }) -- no message
ok("POST /client-errors no message → 400", ngx.status == 400)

s, b = call("GET", "/admin/v1/client-errors")
ok("GET /client-errors → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Audit log route
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/audit-log")
ok("GET /audit-log → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Gateway traces
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/gateways/gw-1/traces")
ok("GET /gateways/:id/traces → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- Dispatcher edge cases
-- ---------------------------------------------------------------------------

-- OPTIONS preflight
local opts_status
ngx.exit = function(code) opts_status = code end
call("OPTIONS", "/admin/v1/anything")
ok("OPTIONS preflight → exit(204)", opts_status == 204, opts_status)
ngx.exit = function(code) response_status = code end

-- 404 for unknown path
s, b = call("GET", "/admin/v1/does-not-exist")
ok("Unknown path → 404", ngx.status == 404)
ok("Unknown path → error in body", b.error ~= nil)

-- Audit log written for POST but NOT for GET
audit_log_calls = {}
call("POST", "/admin/v1/client-errors", { message = "test" })
ok("POST request writes audit log", #audit_log_calls == 1)

audit_log_calls = {}
call("GET", "/admin/v1/stats")
ok("GET request does NOT write audit log", #audit_log_calls == 0)

-- read_body file fallback: when get_body_data returns nil but get_body_file exists
ngx.req.get_body_data = function() return nil end
local tmpfile = os.tmpname()
local fh = io.open(tmpfile, "wb")
fh:write(cjson.encode({ slug = "from-file" }))
fh:close()
ngx.req.get_body_file = function() return tmpfile end
s, b = call("POST", "/admin/v1/tenants")
ok("read_body falls back to body file when get_body_data=nil",
    ngx.status == 201 or ngx.status == 400,  -- slug present → 201
    ngx.status)
ok("read_body file fallback → correct slug",
    ngx.status == 201,
    "expected 201 from file-backed body, got " .. tostring(ngx.status))
ngx.req.get_body_file = nil
ngx.req.get_body_data = function() return nil end

-- ---------------------------------------------------------------------------
-- Model price routes
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/model-prices")
ok("GET /model-prices → 200", ngx.status == 200)

s, b = call("PUT", "/admin/v1/model-prices",
    { provider = "openai", model = "gpt-4o", input_per_1k = 0.01, output_per_1k = 0.03 })
ok("PUT /model-prices valid → 200", ngx.status == 200)

s, b = call("PUT", "/admin/v1/model-prices", { model = "gpt-4o" }) -- no provider
ok("PUT /model-prices missing provider → 400", ngx.status == 400)

s, b = call("DELETE", "/admin/v1/model-prices/openai/gpt-4o")
ok("DELETE /model-prices/:p/:m → 200", ngx.status == 200)

-- ---------------------------------------------------------------------------
-- User search
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/users/search", nil, {})
ok("GET /users/search no email → 400", ngx.status == 400, ngx.status)
ok("GET /users/search no email → error", b.error ~= nil)

s, b = call("GET", "/admin/v1/users/search", nil, { email = "test@example.com" })
ok("GET /users/search with email → 200", ngx.status == 200, ngx.status)
ok("GET /users/search delegates to search_users_by_email",
    storage_calls[#storage_calls].name == "search_users_by_email")
ok("GET /users/search returns array",
    type(b) == "table" and b[1] ~= nil)

-- user with no tenant_id → 400
s, b = call("GET", "/admin/v1/users/search", nil, { email = "x@y.com" },
    { id = "u-notenant", role = "admin", tenant_id = nil })
ok("GET /users/search no tenant on caller → 400", ngx.status == 400, ngx.status)

-- ---------------------------------------------------------------------------
-- POST /tenants/:id/users
-- ---------------------------------------------------------------------------
s, b = call("POST", "/admin/v1/tenants/tn-1/users", {})
ok("POST /tenants/:id/users missing email → 400", ngx.status == 400, ngx.status)
ok("POST /tenants/:id/users → error mentions 'email'",
    b.error and b.error:find("email") ~= nil, b.error)

s, b = call("POST", "/admin/v1/tenants/tn-1/users", { email = "new@example.com" })
ok("POST /tenants/:id/users valid email → 201", ngx.status == 201, ngx.status)
ok("POST /tenants/:id/users → returns id", b.id ~= nil)
ok("POST /tenants/:id/users → email echoed", b.email == "new@example.com")
ok("POST /tenants/:id/users → insert_user called",
    storage_calls[#storage_calls - 1] and
    (storage_calls[#storage_calls - 1].name == "insert_user" or
     storage_calls[#storage_calls].name == "insert_user"))

-- Invalid role should be rejected
s, b = call("POST", "/admin/v1/tenants/tn-1/users",
    { email = "x@y.com", role = "superadmin" })
ok("POST /tenants/:id/users invalid role → 403", ngx.status == 403, ngx.status)

-- ---------------------------------------------------------------------------
-- GET /me/tokens
-- ---------------------------------------------------------------------------
s, b = call("GET", "/admin/v1/me/tokens")
ok("GET /me/tokens → 200", ngx.status == 200, ngx.status)
ok("GET /me/tokens → delegates to list_user_tokens with me.id",
    storage_calls[#storage_calls].name == "list_user_tokens" and
    storage_calls[#storage_calls].args[1] == "user-1")

-- ---------------------------------------------------------------------------
-- POST /me/tokens
-- ---------------------------------------------------------------------------
s, b = call("POST", "/admin/v1/me/tokens", {})
ok("POST /me/tokens missing gateway_id → 400", ngx.status == 400, ngx.status)
ok("POST /me/tokens → error mentions 'gateway_id'",
    b.error and b.error:find("gateway_id") ~= nil, b.error)

s, b = call("POST", "/admin/v1/me/tokens", { gateway_id = "gw-1" })
ok("POST /me/tokens valid → 201", ngx.status == 201, ngx.status)
ok("POST /me/tokens → token field present in response", b.token ~= nil)
ok("POST /me/tokens → token starts with 'myra_'",
    b.token and b.token:sub(1, 5) == "myra_", tostring(b.token))
ok("POST /me/tokens → id returned", b.id ~= nil)

-- ---------------------------------------------------------------------------
-- DELETE /me/tokens/:id
-- ---------------------------------------------------------------------------
-- Override list_user_tokens to return a known token id for the owning user
local _orig_list_user_tokens = storage_stub.list_user_tokens
storage_stub.list_user_tokens = function(uid)
    track("list_user_tokens", uid)
    if uid == "user-1" then return { { id = "tok-mine" } } end
    return {}
end

s, b = call("DELETE", "/admin/v1/me/tokens/tok-mine")
ok("DELETE /me/tokens/:id owned token → 200", ngx.status == 200, ngx.status)
ok("DELETE /me/tokens/:id → delete_auth_token called",
    storage_calls[#storage_calls].name == "delete_auth_token" and
    storage_calls[#storage_calls].args[1] == "tok-mine")

s, b = call("DELETE", "/admin/v1/me/tokens/tok-other")
ok("DELETE /me/tokens/:id not owned → 403", ngx.status == 403, ngx.status)

storage_stub.list_user_tokens = _orig_list_user_tokens  -- restore

-- ---------------------------------------------------------------------------
-- POST /users/:id/resend-invite
-- ---------------------------------------------------------------------------
-- member user (not tenant_admin) → 403
s, b = call("POST", "/admin/v1/users/resend%2Btest/resend-invite", nil, nil,
    { id = "u-member", role = "member", tenant_id = "tn-1" })
ok("POST /users/:id/resend-invite member → 403",
    ngx.status == 403 or ngx.status == 404, ngx.status)

-- tenant_admin, valid user → 200
s, b = call("POST", "/admin/v1/users/user-1/resend-invite", nil, nil,
    { id = "u-admin2", role = "tenant_admin", tenant_id = "tn-1" })
ok("POST /users/:id/resend-invite tenant_admin valid user → 200",
    ngx.status == 200, ngx.status)
ok("POST /users/:id/resend-invite → ok=true", b.ok == true)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
