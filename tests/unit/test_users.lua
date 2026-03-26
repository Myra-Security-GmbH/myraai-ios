-- tests/unit/test_users.lua — tests for user model, auth enforcement, quota, cost tracking
-- Run with: resty tests/runner.lua tests/unit/test_users.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    print  = function() end,
    flush  = function() end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
    },
    var   = {},
    ctx   = {},
    ERR   = 0, WARN = 1, INFO = 2,
    timer = { at = function(_, fn, ...) fn(nil, ...) end },
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Clear module caches between describe blocks
local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- =========================================================================
-- Storage: user CRUD (SQLite with temp files)
-- =========================================================================
describe("storage.sqlite user CRUD", function()
    clear({"storage.sqlite","storage","utils.json","utils.uuid","core.app_config"})

    -- lsqlite3 is a C library loaded from the system Lua path.
    -- Add that path to package.cpath so resty can find it.
    package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

    package.preload["utils.json"] = function()
        local cjson = require("cjson.safe")
        return { encode = cjson.encode, decode = cjson.decode }
    end

    package.preload["utils.uuid"] = function()
        local n = 0
        return { v4 = function() n = n + 1; return string.format("uuid-%04d", n) end }
    end

    -- Use real temp files so migrate() and init() share the same database.
    local cfg_path = os.tmpname() .. "_cfg.db"
    local log_path = os.tmpname() .. "_log.db"
    local db_cfg = { sqlite = { config_db = cfg_path, logs_db = log_path } }

    local storage = require("storage.sqlite")
    storage.migrate(db_cfg)
    storage.init(db_cfg)

    -- Seed a tenant and gateway first (needed for FK constraints)
    local tenant_id  = storage.upsert_tenant("acme", "free", nil)
    local gateway_id = storage.upsert_gateway(tenant_id, "main", {})

    it("insert_user returns an id", function()
        local id, err = storage.insert_user(tenant_id, "alice@example.com", "Alice", "admin")
        assert.is_nil(err)
        assert.not_nil(id)
        assert.is_string(id)
    end)

    it("list_users returns inserted user with tenant_slug", function()
        local users = storage.list_users(tenant_id)
        local found = false
        for _, u in ipairs(users) do
            if u.email == "alice@example.com" then
                found = true
                assert.equal("Alice", u.name)
                assert.equal("admin", u.role)
                assert.equal("acme",  u.tenant_slug)
            end
        end
        assert.is_true(found, "alice@example.com not found in list_users")
    end)

    it("get_user returns the row", function()
        local users = storage.list_users(tenant_id)
        local alice = users[1]
        local row = storage.get_user(alice.id)
        assert.not_nil(row)
        assert.equal("alice@example.com", row.email)
        assert.equal("admin", row.role)
    end)

    it("update_user changes email, name, role", function()
        local users = storage.list_users(tenant_id)
        local alice = users[1]
        local err = storage.update_user(alice.id, "alice2@example.com", "Alice B", "member")
        assert.is_nil(err)
        local row = storage.get_user(alice.id)
        assert.equal("alice2@example.com", row.email)
        assert.equal("Alice B",            row.name)
        assert.equal("member",             row.role)
    end)

    it("delete_user soft-deletes (sets deleted_at)", function()
        local id, _ = storage.insert_user(tenant_id, "temp@example.com", nil, "viewer")
        storage.delete_user(id)
        local row = storage.get_user(id)
        assert.not_nil(row)
        assert.not_nil(row.deleted_at, "deleted_at should be set after soft delete")
    end)

    it("list_users excludes soft-deleted users", function()
        -- temp@example.com was soft-deleted above
        local users = storage.list_users(tenant_id)
        for _, u in ipairs(users) do
            assert.not_equal("temp@example.com", u.email, "soft-deleted user should be excluded")
        end
    end)

    it("insert_user rejects duplicate email within same tenant", function()
        local _, err = storage.insert_user(tenant_id, "alice2@example.com", nil, "member")
        assert.not_nil(err, "duplicate email in same tenant should fail")
    end)

    it("gateway access: set, check, list, delete", function()
        local users = storage.list_users(tenant_id)
        local alice = users[1]

        storage.set_user_gateway_access(alice.id, gateway_id)
        assert.is_true(storage.check_user_gateway_access(alice.id, gateway_id))

        local gws = storage.list_user_gateways(alice.id)
        assert.equal(1, #gws)
        assert.equal(gateway_id, gws[1].id)

        storage.delete_user_gateway_access(alice.id, gateway_id)
        assert.is_false(storage.check_user_gateway_access(alice.id, gateway_id))
    end)

    it("set_user_gateway_access is idempotent (INSERT OR IGNORE)", function()
        local users = storage.list_users(tenant_id)
        local alice = users[1]

        assert.has_no.errors(function()
            storage.set_user_gateway_access(alice.id, gateway_id)
            storage.set_user_gateway_access(alice.id, gateway_id)  -- duplicate — must not fail
        end)
    end)

    it("insert_auth_token with user_id, label, rate_limit, budget_usd", function()
        local id, err = storage.insert_auth_token(
            gateway_id, "hash-abc", {"inference"}, nil,
            "user-id-X", "dev laptop", '{"requests":50,"window_sec":60}', 5.0
        )
        assert.is_nil(err)
        assert.not_nil(id)

        local row = storage.get_auth_token(gateway_id, "hash-abc")
        assert.not_nil(row)
        assert.equal("user-id-X",   row.user_id)
        assert.equal("dev laptop",  row.label)
        assert.equal(5.0,           row.budget_usd)
        assert.not_nil(row.rate_limit)
    end)

    it("list_auth_tokens returns new columns", function()
        local tokens = storage.list_auth_tokens(gateway_id)
        local found = false
        for _, t in ipairs(tokens) do
            if t.label == "dev laptop" then
                found = true
                assert.equal("user-id-X", t.user_id)
                assert.equal(5.0,         t.budget_usd)
            end
        end
        assert.is_true(found, "token with label 'dev laptop' not found")
    end)

    it("list_user_tokens returns tokens linked to a user", function()
        local users = storage.list_users(tenant_id)
        local alice = users[1]
        -- create a token for alice
        storage.insert_auth_token(gateway_id, "hash-alice", {}, nil, alice.id, "alice-token", nil, nil)
        local tokens = storage.list_user_tokens(alice.id)
        local found = false
        for _, t in ipairs(tokens) do
            if t.label == "alice-token" then found = true end
        end
        assert.is_true(found, "alice's token not returned by list_user_tokens")
    end)

    it("insert_auth_token with no user fields (service token) still works", function()
        local id, err = storage.insert_auth_token(gateway_id, "hash-svc", {}, nil)
        assert.is_nil(err)
        assert.not_nil(id)
        local row = storage.get_auth_token(gateway_id, "hash-svc")
        assert.is_nil(row.user_id)
        assert.is_nil(row.label)
        assert.is_nil(row.budget_usd)
        assert.is_nil(row.rate_limit)
    end)
end)

-- =========================================================================
-- middleware/auth.lua — user-bound token enforcement
-- =========================================================================
describe("middleware.auth user enforcement", function()
    local AUTH_MODULES = {
        "middleware.auth", "storage", "utils.crypto", "core.errors"
    }

    local function setup_auth(token_row, user_row)
        clear(AUTH_MODULES)

        -- Shared exit-capture
        local last_exit_code = nil
        _G.ngx.exit   = function(s) last_exit_code = s; error(s) end
        _G.ngx.status = 200

        package.preload["utils.crypto"] = function()
            return {
                sha256_hex = function(t) return "HASH:" .. t end,
            }
        end

        package.preload["core.errors"] = function()
            return {
                codes = {
                    UNAUTHORIZED = { status = 401 },
                    FORBIDDEN    = { status = 403 },
                    INTERNAL     = { status = 500 },
                },
                send = function(code, detail)
                    local codes = { UNAUTHORIZED=401, FORBIDDEN=403, INTERNAL=500 }
                    local s = codes[code] or 500
                    ngx.status = s
                    error(code .. (detail and (": "..detail) or ""))
                end,
            }
        end

        package.preload["storage"] = function()
            return {
                get_auth_token = function(_gw_id, _hash)
                    return token_row, nil
                end,
                get_user = function(_user_id)
                    return user_row, nil
                end,
                check_user_gateway_access = function(_uid, _gid)
                    return user_row and user_row._has_access or false
                end,
            }
        end

        return require("middleware.auth")
    end

    local function make_ctx(token_val)
        _G.ngx.var = { http_x_aig_token = token_val or "tok123" }
        return {
            gateway_id     = "gw-1",
            gateway_config = { auth_required = true },
            log_fields     = {},
        }
    end

    -- --- service token (no user_id) ---

    it("service token with no user_id sets ctx.token_id, no user check", function()
        local auth = setup_auth(
            { id = "tok-id", scopes = "[]", expires_at = nil,
              user_id = nil, label = nil, budget_usd = nil, rate_limit = nil },
            nil
        )
        local ctx = make_ctx()
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.equal("tok-id", ctx.token_id)
        assert.is_nil(ctx.user_id)
    end)

    it("service token propagates label, budget_usd, rate_limit into ctx", function()
        local auth = setup_auth(
            { id = "tok-id", scopes = "[]", expires_at = nil,
              user_id = nil, label = "ci-pipeline",
              budget_usd = 2.5, rate_limit = '{"requests":20,"window_sec":60}' },
            nil
        )
        local ctx = make_ctx()
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.equal("ci-pipeline", ctx.token_label)
        assert.equal(2.5,           ctx.token_budget_usd)
        assert.not_nil(ctx.token_rate_limit)
    end)

    -- --- user token: expired ---

    it("expired token is rejected with UNAUTHORIZED", function()
        local auth = setup_auth(
            { id = "tok-exp", scopes = "[]",
              expires_at = 946684800,   -- 2000-01-01 Unix seconds, in the past
              user_id = nil, label = nil, budget_usd = nil, rate_limit = nil },
            nil
        )
        local ctx = make_ctx()
        local ok, err = pcall(function() auth.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("UNAUTHORIZED"), "expected UNAUTHORIZED, got: " .. tostring(err))
    end)

    -- --- user token: active admin ---

    it("admin user passes without gateway access check", function()
        local auth = setup_auth(
            { id = "tok-adm", scopes = "[]", expires_at = nil,
              user_id = "u-1", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-1", role = "admin", deleted_at = nil, _has_access = false }
        )
        local ctx = make_ctx()
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.equal("u-1",   ctx.user_id)
        assert.equal("admin", ctx.user_role)
    end)

    -- --- user token: viewer is blocked ---

    it("viewer role is rejected with FORBIDDEN on inference", function()
        local auth = setup_auth(
            { id = "tok-vw", scopes = "[]", expires_at = nil,
              user_id = "u-2", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-2", role = "viewer", deleted_at = nil, _has_access = true }
        )
        local ctx = make_ctx()
        local ok, err = pcall(function() auth.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("FORBIDDEN"), "expected FORBIDDEN, got: " .. tostring(err))
    end)

    -- --- member: implicit access to all tenant gateways (no per-gateway check) ---

    it("member has implicit access to all tenant gateways (allowed without explicit grant)", function()
        local auth = setup_auth(
            { id = "tok-mb", scopes = "[]", expires_at = nil,
              user_id = "u-3", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-3", role = "member", deleted_at = nil, _has_access = false }
        )
        local ctx = make_ctx()
        -- In the flat tenant model, members have access to all gateways in their tenant
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.equal("u-3",    ctx.user_id)
        assert.equal("member", ctx.user_role)
    end)

    -- --- member WITH gateway access (also allowed) ---

    it("member with gateway access is allowed", function()
        local auth = setup_auth(
            { id = "tok-mbok", scopes = "[]", expires_at = nil,
              user_id = "u-4", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-4", role = "member", deleted_at = nil, _has_access = true }
        )
        local ctx = make_ctx()
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.equal("u-4",    ctx.user_id)
        assert.equal("member", ctx.user_role)
    end)

    -- --- soft-deleted user ---

    it("soft-deleted user is rejected with UNAUTHORIZED", function()
        local auth = setup_auth(
            { id = "tok-del", scopes = "[]", expires_at = nil,
              user_id = "u-5", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-5", role = "admin", deleted_at = "2024-01-01T00:00:00Z", _has_access = true }
        )
        local ctx = make_ctx()
        local ok, err = pcall(function() auth.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("UNAUTHORIZED"), "expected UNAUTHORIZED, got: " .. tostring(err))
    end)

    -- --- auth skipped when auth_required=false ---

    it("auth is skipped when auth_required=false", function()
        local auth = setup_auth(nil, nil)
        local ctx = {
            gateway_id     = "gw-open",
            gateway_config = { auth_required = false },
            log_fields     = {},
        }
        _G.ngx.var = { http_x_aig_token = nil }
        assert.has_no.errors(function() auth.run(ctx) end)
        assert.is_nil(ctx.token_id)
    end)
end)

-- =========================================================================
-- middleware/quota.lua — per-token budget enforcement
-- =========================================================================
describe("middleware.quota per-token budget", function()
    local QUOTA_MODULES = { "middleware.quota", "state", "storage", "utils.budget", "utils.webhook", "core.errors" }

    local function setup_quota(token_spend_micro, gw_spend_micro)
        clear(QUOTA_MODULES)

        package.preload["core.errors"] = function()
            return {
                send = function(code, detail)
                    error(code .. (detail and (": " .. detail) or ""))
                end,
            }
        end

        package.preload["utils.budget"] = function()
            return { current_period = function() return "2026-03" end }
        end

        package.preload["utils.webhook"] = function()
            return { fire = function() end }
        end

        package.preload["storage"] = function()
            return {
                get_spend = function(entity_type, entity_id, _period)
                    if entity_type == "token" and entity_id == "tok-1" then
                        return token_spend_micro or 0
                    elseif entity_type == "gateway" and entity_id == "gw-1" then
                        return gw_spend_micro or 0
                    end
                    return 0
                end,
            }
        end

        local cache = {}
        package.preload["state"] = function()
            return {
                cache_get = function(k)        return cache[k] end,
                cache_set = function(k, v, _t) cache[k] = v end,
                cache_del = function(k)        cache[k] = nil end,
            }
        end

        return require("middleware.quota")
    end

    local function make_ctx(token_budget, gw_budget, token_id)
        return {
            token_id         = token_id or "tok-1",
            token_budget_usd = token_budget,
            gateway_id       = "gw-1",
            gateway_config   = { budget_usd = gw_budget },
            log_fields       = {},
        }
    end

    it("no budget configured — passes through", function()
        local quota = setup_quota(0, nil)
        local ctx = make_ctx(nil, nil)
        assert.has_no.errors(function() quota.run(ctx) end)
    end)

    it("token budget not exceeded — passes through", function()
        local quota = setup_quota(1000, nil)   -- 1000 micro-USD spent, budget is $5
        local ctx = make_ctx(5.0, nil)
        assert.has_no.errors(function() quota.run(ctx) end)
        assert.not_nil(ctx.log_fields.token_quota_remaining)
    end)

    it("token budget exactly at limit — blocked", function()
        -- budget $1.0 = 1e6 micro; spent = 1e6
        local quota = setup_quota(1000000, nil)
        local ctx = make_ctx(1.0, nil)
        local ok, err = pcall(function() quota.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("QUOTA_EXCEEDED"), "expected QUOTA_EXCEEDED, got: " .. tostring(err))
    end)

    it("token budget exceeded — blocked before gateway budget check", function()
        -- token over budget, gateway has plenty
        local quota = setup_quota(5000000, 0)
        local ctx = make_ctx(1.0, 100.0)
        local ok, err = pcall(function() quota.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("QUOTA_EXCEEDED"), "expected QUOTA_EXCEEDED from token budget")
    end)

    it("gateway budget exceeded — blocked when token has no budget", function()
        local quota = setup_quota(0, 2000000)   -- gw spent $2, budget $1
        local ctx = make_ctx(nil, 1.0)
        local ok, err = pcall(function() quota.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("QUOTA_EXCEEDED"), "expected QUOTA_EXCEEDED from gateway budget")
    end)

    it("token budget not exceeded but gateway budget is — gateway blocks", function()
        local quota = setup_quota(500, 2000000)  -- token ok, gw over
        local ctx = make_ctx(5.0, 1.0)
        local ok, err = pcall(function() quota.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("QUOTA_EXCEEDED"), "gateway budget should block")
    end)

    it("quota_remaining is set in log_fields for gateway budget", function()
        local quota = setup_quota(0, 500000)   -- gw spent $0.50 of $1.00
        local ctx = make_ctx(nil, 1.0)
        quota.run(ctx)
        assert.not_nil(ctx.log_fields.quota_remaining)
        assert(ctx.log_fields.quota_remaining > 0, "quota_remaining should be positive")
    end)

    it("token_quota_remaining is set in log_fields for token budget", function()
        local quota = setup_quota(250000, nil)  -- $0.25 of $1.00 spent
        local ctx = make_ctx(1.0, nil)
        quota.run(ctx)
        assert.not_nil(ctx.log_fields.token_quota_remaining)
        assert(ctx.log_fields.token_quota_remaining > 0, "token_quota_remaining should be positive")
    end)
end)

-- =========================================================================
-- middleware/cost.lua — per-token counter increment
-- =========================================================================
describe("middleware.cost per-token counter", function()
    local COST_MODULES = { "middleware.cost", "observability.cost_table", "storage", "utils.budget", "state" }

    local function setup_cost(cost_result)
        clear(COST_MODULES)

        package.preload["observability.cost_table"] = function()
            return { calculate = function() return cost_result or 0.001 end }
        end

        package.preload["utils.budget"] = function()
            return { current_period = function() return "2026-03" end }
        end

        -- spend[entity_type][entity_id] = micro_usd
        local spend = {}
        package.preload["storage"] = function()
            return {
                incr_spend = function(entity_type, entity_id, _period, micro)
                    spend[entity_type] = spend[entity_type] or {}
                    spend[entity_type][entity_id] = (spend[entity_type][entity_id] or 0) + micro
                end,
            }
        end

        package.preload["state"] = function()
            return { cache_del = function() end }
        end

        local mod = require("middleware.cost")
        return mod, spend
    end

    it("increments gateway counter for all requests", function()
        local cost, spend = setup_cost(0.002)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id = "gw-1",
            token_id = nil, token_budget_usd = nil,
        }
        cost.run(ctx)
        assert.equal(2000, spend.gateway and spend.gateway["gw-1"])
        assert.equal(0.002, ctx.cost_usd)
    end)

    it("increments token counter when token has a budget cap", function()
        local cost, spend = setup_cost(0.005)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 200, output_tokens = 100,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-2",
            token_id     = "tok-99",
            token_budget_usd = 10.0,   -- token has a budget
        }
        cost.run(ctx)
        assert.equal(5000, spend.gateway and spend.gateway["gw-2"],       "gateway counter should be incremented")
        assert.equal(5000, spend.token   and spend.token["tok-99"],       "token counter should be incremented")
    end)

    it("does not increment token counter when token has no budget cap", function()
        local cost, spend = setup_cost(0.003)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-3",
            token_id     = "tok-no-budget",
            token_budget_usd = nil,   -- no per-token budget
        }
        cost.run(ctx)
        assert.equal(3000, spend.gateway and spend.gateway["gw-3"])
        assert.is_nil(spend.token and spend.token["tok-no-budget"])
    end)

    it("does not increment token counter when token_id is nil (open gateway)", function()
        local cost, spend = setup_cost(0.001)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-4",
            token_id     = nil,
            token_budget_usd = nil,
        }
        cost.run(ctx)
        assert.equal(1000, spend.gateway and spend.gateway["gw-4"])
        assert.is_nil(spend.token, "no per-token spend should be recorded when token_id is nil")
    end)

    it("zero cost does not increment any counter", function()
        local cost, counters = setup_cost(0)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 0, output_tokens = 0,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-5",
            token_id     = "tok-zero",
            token_budget_usd = 1.0,
        }
        cost.run(ctx)
        assert.is_nil(counters["budget:gw-5"])
        assert.is_nil(counters["budget:token:tok-zero"])
    end)
end)

-- =========================================================================
-- observability/logger.lua — user_id and token_label in log fields
-- =========================================================================
describe("observability.logger user attribution", function()
    local LOG_MODULES = {
        "observability.logger", "storage", "utils.json", "utils.uuid"
    }

    local last_log = nil

    local function setup_logger()
        clear(LOG_MODULES)

        package.preload["utils.json"] = function()
            local cjson = require("cjson.safe")
            return { encode = cjson.encode, decode = cjson.decode }
        end

        package.preload["utils.uuid"] = function()
            return { v4 = function() return "req-uuid" end }
        end

        package.preload["storage"] = function()
            return {
                insert_log = function(f)
                    last_log = f
                    return nil  -- no error
                end,
            }
        end

        _G.ngx.now    = function() return 1700000000.0 end
        _G.ngx.status = 200

        return require("observability.logger")
    end

    it("emits user_id when set in ctx", function()
        local logger = setup_logger()
        local ctx = {
            request_id     = "r-1",
            tenant_id      = "t-1",
            gateway_id     = "g-1",
            provider       = "openai",
            model          = "gpt-4o",
            provider_status= 200,
            cache_hit      = false,
            input_tokens   = 10, output_tokens = 5,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            cost_usd       = 0.001,
            start_ms       = 1700000000.0 * 1000,
            gateway_config = { log_payloads = false },
            upstream_attempts = 1,
            log_fields     = {},
            user_id        = "user-abc",
            token_label    = "laptop",
        }
        logger.emit(ctx)
        assert.not_nil(last_log)
        assert.equal("user-abc", last_log.user_id)
        assert.equal("laptop",   last_log.token_label)
    end)

    it("emits nil user_id for service tokens", function()
        local logger = setup_logger()
        local ctx = {
            request_id     = "r-2",
            tenant_id      = "t-1",
            gateway_id     = "g-1",
            provider       = "openai",
            model          = "gpt-4o",
            provider_status= 200,
            cache_hit      = false,
            input_tokens   = 0, output_tokens = 0,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            cost_usd       = 0,
            start_ms       = 1700000000.0 * 1000,
            gateway_config = { log_payloads = false },
            upstream_attempts = 1,
            log_fields     = {},
            user_id        = nil,   -- service token
            token_label    = nil,
        }
        logger.emit(ctx)
        assert.not_nil(last_log)
        assert.is_nil(last_log.user_id)
        assert.is_nil(last_log.token_label)
    end)

    it("skip_log prevents emission", function()
        local logger = setup_logger()
        last_log = nil
        local ctx = {
            skip_log       = true,
            gateway_config = { log_payloads = false },
            log_fields     = {},
        }
        logger.emit(ctx)
        assert.is_nil(last_log)
    end)
end)

-- =========================================================================
-- get_analytics_depth — user_id attribution pipeline (regression for By User tab)
-- =========================================================================
-- Regression: the by_user SQL never included tenant_id, so the "By User"
-- analytics tab showed nothing when filtered to a specific tenant.
-- These tests pin the contract that:
--   1. request_log rows with user_id set appear in by_user
--   2. each by_user row carries tenant_id (needed for frontend tenant scoping)
--   3. rows with user_id IS NULL are excluded from by_user
--   4. get_analytics_depth returns the correct by_user data end-to-end
--   5. a user-attributed token round-trips: auth sets ctx.user_id, logger
--      writes it to insert_log, get_analytics_depth surfaces it in by_user

describe("get_analytics_depth — user_id attribution in by_user", function()
    -- Fresh isolated DBs so this describe does not share state with earlier ones.
    package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
    package.loaded["storage.sqlite"] = nil
    package.loaded["storage"]        = nil

    package.preload["utils.json"] = package.preload["utils.json"] or function()
        local cjson = require("cjson.safe")
        return { encode = cjson.encode, decode = cjson.decode }
    end
    package.preload["utils.uuid"] = package.preload["utils.uuid"] or function()
        local n = 0
        return { v4 = function() n = n + 1; return string.format("ua-uuid-%04d", n) end }
    end

    local sqlite3 = require("lsqlite3")
    local cfg_path = "/tmp/test_ua_cfg.db"
    local log_path = "/tmp/test_ua_log.db"
    os.remove(cfg_path); os.remove(log_path)

    local storage = require("storage.sqlite")
    storage.migrate({ sqlite = { config_db = cfg_path, logs_db = log_path } })
    storage.init   ({ sqlite = { config_db = cfg_path, logs_db = log_path } })

    local ldb = sqlite3.open(log_path)
    local seq = 0

    local TENANT_1 = "t1111111-0000-0000-0000-000000000001"
    local TENANT_2 = "t2222222-0000-0000-0000-000000000002"
    local USER_A   = "ua-user-alice"
    local USER_B   = "ua-user-bob"

    local NOW_MS = math.floor(ngx.now()) * 1000   -- epoch ms

    local function insert_req(tenant_id, user_id, cost)
        seq = seq + 1
        local ts = NOW_MS - 1000  -- 1 s ago, within the default 30d window
        local sql = string.format([[
            INSERT INTO request_log
                (id, tenant_id, gateway_id, provider, model, status,
                 cached, input_tokens, output_tokens,
                 cache_creation_tokens, cache_read_tokens,
                 cost_usd, latency_ms, ts,
                 meta, blocked, upstream_attempts, request_size_bytes, scrub_applied
                 %s)
            VALUES ('ua-req-%04d','%s','g1','openai','gpt-4o',200,
                    0,10,5,0,0,
                    %.4f,100,%d,
                    '{}',0,1,512,0
                    %s)
        ]],
            user_id and ", user_id" or "",
            seq, tenant_id,
            cost or 0.001,
            ts,
            user_id and (", '" .. user_id .. "'") or ""
        )
        ldb:exec(sql)
    end

    it("by_user is empty when all requests have no user_id", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, nil, 0.001)
        insert_req(TENANT_2, nil, 0.002)

        local depth = storage.get_analytics_depth()
        assert.not_nil(depth)
        assert.equal(0, #depth.by_user,
            "by_user must be empty when all request_log rows have user_id IS NULL")
    end)

    it("by_user contains a row when a request has user_id set", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.005)

        local depth = storage.get_analytics_depth()
        assert.equal(1, #depth.by_user)
        assert.equal(USER_A, depth.by_user[1].user_id,
            "by_user row must have correct user_id")
    end)

    it("by_user row includes tenant_id (regression: was missing, broke By User tab)", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.003)

        local depth = storage.get_analytics_depth()
        assert.equal(1, #depth.by_user)
        assert.equal(TENANT_1, depth.by_user[1].tenant_id,
            "by_user row MUST carry tenant_id for frontend tenant scoping")
    end)

    it("by_user excludes rows without user_id even when other users exist", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.001)   -- attributed
        insert_req(TENANT_1, nil,    0.001)   -- NOT attributed — must be excluded
        insert_req(TENANT_2, nil,    0.001)   -- NOT attributed — must be excluded

        local depth = storage.get_analytics_depth()
        assert.equal(1, #depth.by_user,
            "anonymous requests must not appear in by_user")
        assert.equal(USER_A, depth.by_user[1].user_id)
    end)

    it("by_user aggregates multiple requests from the same user correctly", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.002)
        insert_req(TENANT_1, USER_A, 0.003)
        insert_req(TENANT_1, USER_A, 0.005)

        local depth = storage.get_analytics_depth()
        assert.equal(1, #depth.by_user)
        assert.equal(3,   depth.by_user[1].requests)
        -- cost must be the rounded sum of 0.002+0.003+0.005 = 0.010
        assert.is_true(depth.by_user[1].cost_usd >= 0.0099 and
                        depth.by_user[1].cost_usd <= 0.0101,
            "cost_usd mismatch: " .. tostring(depth.by_user[1].cost_usd))
    end)

    it("by_user keeps users from different tenants separate (tenant_id is part of GROUP BY)", function()
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.010)
        insert_req(TENANT_2, USER_B, 0.020)

        local depth = storage.get_analytics_depth()
        assert.equal(2, #depth.by_user)

        -- Build a lookup table for easy assertions
        local by_uid = {}
        for _, row in ipairs(depth.by_user) do
            by_uid[row.user_id] = row
        end

        assert.not_nil(by_uid[USER_A])
        assert.equal(TENANT_1, by_uid[USER_A].tenant_id)
        assert.not_nil(by_uid[USER_B])
        assert.equal(TENANT_2, by_uid[USER_B].tenant_id)
    end)

    it("same user_id in two tenants produces two separate by_user rows", function()
        -- Edge case: same user_id string appears in requests for two different
        -- tenants (e.g. shared identity provider).  The GROUP BY must separate them.
        ldb:exec("DELETE FROM request_log")
        insert_req(TENANT_1, USER_A, 0.001)
        insert_req(TENANT_2, USER_A, 0.002)   -- same user_id, different tenant

        local depth = storage.get_analytics_depth()
        assert.equal(2, #depth.by_user,
            "same user_id across two tenants must appear as two separate rows")

        local t1_row, t2_row
        for _, row in ipairs(depth.by_user) do
            if row.tenant_id == TENANT_1 then t1_row = row end
            if row.tenant_id == TENANT_2 then t2_row = row end
        end
        assert.not_nil(t1_row, "TENANT_1 row missing")
        assert.not_nil(t2_row, "TENANT_2 row missing")
        assert.equal(USER_A, t1_row.user_id)
        assert.equal(USER_A, t2_row.user_id)
    end)

    -- End-to-end pipeline: token with user_id → auth sets ctx.user_id →
    -- logger.emit writes user_id to insert_log → get_analytics_depth surfaces it.
    it("full pipeline: user-attributed token flows user_id into request_log via insert_log", function()
        ldb:exec("DELETE FROM request_log")

        -- Simulate what the auth middleware + logger do together:
        -- auth.run sets ctx.user_id; logger.emit calls storage.insert_log(f)
        -- where f.user_id = ctx.user_id.
        local f = {
            id                 = "ua-pipe-req-001",
            tenant_id          = TENANT_1,
            gateway_id         = "gw-pipe",
            provider           = "openai",
            model              = "gpt-4o",
            status             = 200,
            cached             = false,
            input_tokens       = 100,
            output_tokens      = 50,
            cache_creation_tokens = 0,
            cache_read_tokens  = 0,
            cost_usd           = 0.007,
            latency_ms         = 200,
            ts                 = NOW_MS - 500,
            meta               = {},
            blocked            = false,
            upstream_attempts  = 1,
            request_size_bytes = 512,
            scrub_applied      = false,
            -- set by auth middleware → flows to logger → insert_log
            user_id            = USER_A,
            token_label        = "my-dev-token",
        }
        local err = storage.insert_log(f)
        assert.is_nil(err, "insert_log must not return an error")

        local depth = storage.get_analytics_depth()
        assert.equal(1, #depth.by_user,
            "by_user must contain one row after inserting a user-attributed request")
        assert.equal(USER_A,   depth.by_user[1].user_id)
        assert.equal(TENANT_1, depth.by_user[1].tenant_id)
        assert.equal(1,        depth.by_user[1].requests)
    end)
end)

-- =========================================================================
-- admin/api.lua — POST /gateways/:id/tokens respects user_id in body
-- =========================================================================
-- Regression: the gateway token endpoint hardcoded nil for user_id, so tokens
-- created via the UI or API gateway endpoint never got user attribution, making
-- the By User analytics tab permanently empty for those users.
-- The fix: pass b.user_id from the request body instead of nil.

describe("admin/api POST /gateways/:id/tokens passes user_id from body", function()
    local API_MODULES = {
        "admin.api", "storage", "auth.byok", "utils.crypto",
        "utils.json", "providers", "core.app_config", "admin.auth",
    }
    local function clear_api()
        for _, n in ipairs(API_MODULES) do
            package.loaded[n]  = nil
            package.preload[n] = nil
        end
    end

    local function setup_api(captured)
        clear_api()

        package.preload["utils.json"] = function()
            local cjson = require("cjson.safe")
            return { encode = cjson.encode, decode = cjson.decode, null = cjson.null }
        end
        package.preload["utils.crypto"] = function()
            return {
                random_hex  = function(n) return string.rep("a", n * 2) end,
                sha256_hex  = function(s) return "HASH:" .. s end,
            }
        end
        package.preload["auth.byok"]   = function() return { get = function() return nil end } end
        package.preload["providers"]   = function() return { list = function() return {} end } end
        package.preload["core.app_config"] = function() return { get = function() return {} end } end
        package.preload["admin.auth"]  = function() return { require_session = function() end } end

        package.preload["storage"] = function()
            return {
                insert_auth_token = function(gw_id, hash, scopes, expires_at, user_id, label, rl, budget)
                    captured.gateway_id = gw_id
                    captured.user_id    = user_id
                    captured.label      = label
                    return "new-token-id", nil
                end,
                get_gateway_by_id   = function() return { id = "gw-test", tenant_id = "t-1" } end,
                insert_audit_log = function() end,
                -- stubs for routes that run at load time or list calls
                list_auth_tokens = function() return {} end,
            }
        end

        -- Set up a tenant_admin session so require_tenant_admin() passes
        ngx.ctx.admin_user = { id = "u-admin", role = "tenant_admin", tenant_id = "t-1" }

        local response = {}
        ngx.req.get_method    = function() return "POST" end
        ngx.req.get_uri_args  = function() return {} end
        ngx.req.read_body     = function() end
        ngx.var.remote_addr   = "127.0.0.1"
        ngx.print             = function(s) response.body = s end
        ngx.exit              = function(s) error("ngx.exit:" .. tostring(s)) end

        return require("admin.api"), response
    end

    it("user_id from body is stored on the token (not silently dropped)", function()
        local captured = {}
        local api = setup_api(captured)

        local body_json = require("cjson.safe").encode({
            user_id = "user-sascha", label = "my-laptop"
        })
        ngx.req.get_body_data = function() return body_json end
        ngx.var.uri = "/admin/v1/gateways/gw-test/tokens"

        api.handle()

        assert.equal("user-sascha", captured.user_id,
            "user_id from request body must be passed to insert_auth_token — "
            .. "regression: endpoint previously hardcoded nil, breaking By User analytics")
    end)

    it("user_id absent from body results in nil (service token)", function()
        local captured = {}
        local api = setup_api(captured)

        local body_json = require("cjson.safe").encode({ label = "ci-bot" })
        ngx.req.get_body_data = function() return body_json end
        ngx.var.uri = "/admin/v1/gateways/gw-test/tokens"

        api.handle()

        assert.is_nil(captured.user_id,
            "omitting user_id from body must produce nil (service/gateway-level token)")
    end)

    it("explicit null user_id in body results in nil", function()
        local captured = {}
        local api, _ = setup_api(captured)

        local cjson = require("cjson.safe")
        local body_json = cjson.encode({ user_id = cjson.null, label = "svc" })
        ngx.req.get_body_data = function() return body_json end
        ngx.var.uri = "/admin/v1/gateways/gw-test/tokens"

        api.handle()

        assert.is_nil(captured.user_id,
            "JSON null user_id must be normalised to nil by nullable()")
    end)
end)
