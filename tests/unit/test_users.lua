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
    var = {},
    ctx = {},
    ERR = 0, WARN = 1, INFO = 2,
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

    -- --- member without gateway access ---

    it("member without gateway access is rejected with FORBIDDEN", function()
        local auth = setup_auth(
            { id = "tok-mb", scopes = "[]", expires_at = nil,
              user_id = "u-3", label = nil, budget_usd = nil, rate_limit = nil },
            { id = "u-3", role = "member", deleted_at = nil, _has_access = false }
        )
        local ctx = make_ctx()
        local ok, err = pcall(function() auth.run(ctx) end)
        assert.is_false(ok)
        assert(tostring(err):find("FORBIDDEN"), "expected FORBIDDEN, got: " .. tostring(err))
    end)

    -- --- member WITH gateway access ---

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
    local QUOTA_MODULES = { "middleware.quota", "state", "core.errors" }

    local function setup_quota(token_counter, gw_counter)
        clear(QUOTA_MODULES)

        package.preload["core.errors"] = function()
            return {
                send = function(code, detail)
                    error(code .. (detail and (": " .. detail) or ""))
                end,
            }
        end

        local counters = {}
        if token_counter then counters["budget:token:tok-1"] = token_counter end
        if gw_counter    then counters["budget:gw-1"]        = gw_counter    end

        package.preload["state"] = function()
            return {
                counter_get  = function(k)    return counters[k] or 0 end,
                counter_incr = function(k, d) counters[k] = (counters[k] or 0) + d; return counters[k] end,
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
    local COST_MODULES = { "middleware.cost", "observability.cost_table", "state" }

    local function setup_cost(cost_result)
        clear(COST_MODULES)

        package.preload["observability.cost_table"] = function()
            return { calculate = function() return cost_result or 0.001 end }
        end

        local counters = {}
        package.preload["state"] = function()
            return {
                counter_get  = function(k) return counters[k] or 0 end,
                counter_incr = function(k, d)
                    counters[k] = (counters[k] or 0) + d
                    return counters[k]
                end,
            }
        end

        local mod = require("middleware.cost")
        return mod, counters
    end

    it("increments gateway counter for all requests", function()
        local cost, counters = setup_cost(0.002)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id = "gw-1",
            token_id = nil, token_budget_usd = nil,
        }
        cost.run(ctx)
        assert.equal(2000, counters["budget:gw-1"])
        assert.equal(0.002, ctx.cost_usd)
    end)

    it("increments token counter when token has a budget cap", function()
        local cost, counters = setup_cost(0.005)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 200, output_tokens = 100,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-2",
            token_id     = "tok-99",
            token_budget_usd = 10.0,   -- token has a budget
        }
        cost.run(ctx)
        assert.equal(5000, counters["budget:gw-2"],         "gateway counter should be incremented")
        assert.equal(5000, counters["budget:token:tok-99"], "token counter should be incremented")
    end)

    it("does not increment token counter when token has no budget cap", function()
        local cost, counters = setup_cost(0.003)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-3",
            token_id     = "tok-no-budget",
            token_budget_usd = nil,   -- no per-token budget
        }
        cost.run(ctx)
        assert.equal(3000, counters["budget:gw-3"])
        assert.is_nil(counters["budget:token:tok-no-budget"])
    end)

    it("does not increment token counter when token_id is nil (open gateway)", function()
        local cost, counters = setup_cost(0.001)
        local ctx = {
            provider = "openai", model = "gpt-4o",
            input_tokens = 100, output_tokens = 50,
            cache_creation_tokens = 0, cache_read_tokens = 0,
            gateway_id   = "gw-4",
            token_id     = nil,
            token_budget_usd = nil,
        }
        cost.run(ctx)
        assert.equal(1000, counters["budget:gw-4"])
        -- no budget:token:* keys should have been created
        local found = false
        for k, _ in pairs(counters) do
            if k:find("budget:token:") then found = true end
        end
        assert.is_false(found, "no per-token counter should be created when token_id is nil")
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
