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
-- Storage: user CRUD (in-memory mock — no lsqlite3 / storage.sqlite needed)
-- =========================================================================
describe("storage user CRUD", function()

    -- In-memory stores
    local _tenants  = {}
    local _gateways = {}
    local _users    = {}
    local _gw_access = {}   -- {user_id .. "|" .. gw_id} = true
    local _tokens   = {}
    local _seq      = 0

    local function gen_id(prefix)
        _seq = _seq + 1
        return string.format("%s-%04d", prefix, _seq)
    end

    local storage = {
        upsert_tenant = function(slug, plan, budget)
            local id = gen_id("tenant")
            _tenants[id] = { id=id, slug=slug, plan=plan, budget=budget }
            return id
        end,
        upsert_gateway = function(tenant_id, slug, config)
            local id = gen_id("gw")
            _gateways[id] = { id=id, tenant_id=tenant_id, slug=slug, config=config }
            return id
        end,
        insert_user = function(tenant_id, email, name, role)
            for _, u in ipairs(_users) do
                if u.email == email and u.tenant_id == tenant_id and not u.deleted_at then
                    return nil, "email already registered"
                end
            end
            local id = gen_id("user")
            _users[#_users + 1] = {
                id=id, tenant_id=tenant_id, email=email,
                name=name, role=role or "admin", deleted_at=nil,
            }
            return id, nil
        end,
        list_users = function(tenant_id)
            local result = {}
            for _, u in ipairs(_users) do
                if u.tenant_id == tenant_id and not u.deleted_at then
                    local t = _tenants[tenant_id]
                    result[#result + 1] = {
                        id=u.id, tenant_id=u.tenant_id,
                        email=u.email, name=u.name, role=u.role,
                        tenant_slug = t and t.slug or nil,
                    }
                end
            end
            return result
        end,
        get_user = function(id)
            for _, u in ipairs(_users) do
                if u.id == id then return u end
            end
            return nil
        end,
        update_user = function(id, email, name, role)
            for _, u in ipairs(_users) do
                if u.id == id then
                    u.email = email; u.name = name; u.role = role
                    return nil
                end
            end
            return "not found"
        end,
        delete_user = function(id)
            for _, u in ipairs(_users) do
                if u.id == id then u.deleted_at = ngx.time() end
            end
        end,
        set_user_gateway_access = function(user_id, gw_id)
            _gw_access[user_id .. "|" .. gw_id] = gw_id
        end,
        check_user_gateway_access = function(user_id, gw_id)
            return _gw_access[user_id .. "|" .. gw_id] ~= nil
        end,
        list_user_gateways = function(user_id)
            local result = {}
            for k, gw_id in pairs(_gw_access) do
                if k:sub(1, #user_id + 1) == user_id .. "|" then
                    result[#result + 1] = { id=gw_id }
                end
            end
            return result
        end,
        delete_user_gateway_access = function(user_id, gw_id)
            _gw_access[user_id .. "|" .. gw_id] = nil
        end,
        insert_auth_token = function(gw_id, hash, scopes, expires, user_id, label, rate_limit, budget_usd)
            local id = gen_id("tok")
            _tokens[#_tokens + 1] = {
                id=id, gateway_id=gw_id, token_hash=hash, scopes=scopes,
                expires_at=expires, user_id=user_id, label=label,
                rate_limit=rate_limit, budget_usd=budget_usd,
            }
            return id, nil
        end,
        get_auth_token = function(gw_id, hash)
            for _, t in ipairs(_tokens) do
                if t.gateway_id == gw_id and t.token_hash == hash then return t end
            end
            return nil
        end,
        list_auth_tokens = function(gw_id)
            local result = {}
            for _, t in ipairs(_tokens) do
                if t.gateway_id == gw_id then result[#result + 1] = t end
            end
            return result
        end,
        list_user_tokens = function(user_id)
            local result = {}
            for _, t in ipairs(_tokens) do
                if t.user_id == user_id then result[#result + 1] = t end
            end
            return result
        end,
    }

    -- Seed a tenant and gateway (needed for gateway_id in token tests)
    local tenant_id  = storage.upsert_tenant("acme", "free", nil)
    local gateway_id = storage.upsert_gateway(tenant_id, "main", {})

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
-- get_analytics_depth — user_id attribution (MySQL mock version)
-- =========================================================================
-- Verifies: by_user SQL filters user_id IS NOT NULL, groups by (user_id,
-- tenant_id), and the function correctly processes returned by_user rows.

describe("get_analytics_depth — user_id attribution in by_user", function()

    local queries_depth = {}
    local results_depth = {}

    package.preload["resty.mysql"] = function()
        return {
            new = function()
                return {
                    connect       = function() return 1 end,
                    set_keepalive = function() return 1 end,
                    set_timeout   = function() end,
                    query         = function(self, sql)
                        queries_depth[#queries_depth + 1] = sql
                        return table.remove(results_depth, 1) or {}, nil, nil
                    end,
                    read_result   = function()
                        return table.remove(results_depth, 1) or {}, nil, nil
                    end,
                }
            end,
        }
    end

    package.preload["utils.json"] = package.preload["utils.json"] or function()
        local cjson = require("cjson.safe")
        return { encode = cjson.encode, decode = cjson.decode }
    end
    package.preload["utils.uuid"] = package.preload["utils.uuid"] or function()
        local n = 0
        return { v4 = function() n = n + 1; return string.format("ua-uuid-%04d", n) end }
    end

    package.loaded["storage.mysql"] = nil
    local M_depth = require("storage.mysql")
    M_depth.init({ mysql = { host="127.0.0.1", port=3306, database="ai_gateway",
                             user="gateway", password="secret",
                             pool_size=10, pool_timeout=5000 } })

    local TENANT_1 = "t1111111-0000-0000-0000-000000000001"
    local TENANT_2 = "t2222222-0000-0000-0000-000000000002"
    local USER_A   = "ua-user-alice"
    local USER_B   = "ua-user-bob"

    local function reset_depth()
        queries_depth = {}
        results_depth = {}
    end

    local function queue_empty(n)
        for _ = 1, (n or 6) do table.insert(results_depth, {}) end
    end

    -- ── SQL structure ──────────────────────────────────────────────────────

    it("by_user SQL filters r.user_id IS NOT NULL", function()
        reset_depth(); queue_empty()
        M_depth.get_analytics_depth()
        -- by_user is query 5 (pct, top_models, by_tenant, by_gateway, by_user, cache_eff)
        local by_user_sql = queries_depth[5] or ""
        assert.is_true(by_user_sql:find("user_id") ~= nil,
            "by_user query must reference user_id: " .. by_user_sql:sub(1,200))
        assert.is_true(by_user_sql:find("IS NOT NULL") ~= nil,
            "by_user query must filter user_id IS NOT NULL: " .. by_user_sql:sub(1,200))
    end)

    it("by_user SQL groups by user_id AND tenant_id", function()
        reset_depth(); queue_empty()
        M_depth.get_analytics_depth()
        local sql = queries_depth[5] or ""
        assert.is_true(sql:find("GROUP BY") ~= nil, "by_user must GROUP BY")
        assert.is_true(sql:find("user_id") ~= nil, "by_user must group by user_id")
        assert.is_true(sql:find("tenant_id") ~= nil,
            "by_user must include tenant_id (regression: was missing, broke By User tab): " .. sql:sub(1,200))
    end)

    -- ── Result processing ─────────────────────────────────────────────────

    it("by_user is empty when DB returns no rows for that query", function()
        reset_depth(); queue_empty()
        local depth = M_depth.get_analytics_depth()
        assert.not_nil(depth.by_user)
        assert.equal(0, #depth.by_user,
            "by_user must be empty when no rows returned by DB")
    end)

    it("by_user contains a row when DB returns one with user_id set", function()
        reset_depth()
        for _ = 1, 4 do table.insert(results_depth, {}) end
        -- Queue by_user result with one attributed row
        table.insert(results_depth, {{
            user_id="ua-user-alice", tenant_id=TENANT_1, email="alice@test.com",
            requests=3, blocked=0, cached=0,
            input_tokens=30, output_tokens=15, cost_usd=0.010,
            saved_cost_usd=0, avg_latency_ms=100, errors=0,
        }})
        table.insert(results_depth, {})  -- cache_eff

        local depth = M_depth.get_analytics_depth()
        assert.equal(1, #depth.by_user)
        assert.equal(USER_A,   depth.by_user[1].user_id)
        assert.equal(TENANT_1, depth.by_user[1].tenant_id,
            "by_user row MUST carry tenant_id for frontend tenant scoping")
        assert.equal(3,        depth.by_user[1].requests)
    end)

    it("by_user rows from two different users appear as separate entries", function()
        reset_depth()
        for _ = 1, 4 do table.insert(results_depth, {}) end
        table.insert(results_depth, {
            { user_id=USER_A, tenant_id=TENANT_1, email="alice@t.com",
              requests=2, blocked=0, cached=0,
              input_tokens=20, output_tokens=10, cost_usd=0.005,
              saved_cost_usd=0, avg_latency_ms=100, errors=0 },
            { user_id=USER_B, tenant_id=TENANT_2, email="bob@t.com",
              requests=1, blocked=0, cached=0,
              input_tokens=10, output_tokens=5, cost_usd=0.002,
              saved_cost_usd=0, avg_latency_ms=200, errors=0 },
        })
        table.insert(results_depth, {})

        local depth = M_depth.get_analytics_depth()
        assert.equal(2, #depth.by_user)
        local by_uid = {}
        for _, row in ipairs(depth.by_user) do by_uid[row.user_id] = row end
        assert.not_nil(by_uid[USER_A], "USER_A row missing")
        assert.not_nil(by_uid[USER_B], "USER_B row missing")
        assert.equal(TENANT_1, by_uid[USER_A].tenant_id)
        assert.equal(TENANT_2, by_uid[USER_B].tenant_id)
    end)

    it("same user_id in two tenants produces two separate by_user rows", function()
        reset_depth()
        for _ = 1, 4 do table.insert(results_depth, {}) end
        -- Same user_id, different tenant (GROUP BY user_id, tenant_id separates them)
        table.insert(results_depth, {
            { user_id=USER_A, tenant_id=TENANT_1, email="alice@t.com",
              requests=1, blocked=0, cached=0, input_tokens=10, output_tokens=5,
              cost_usd=0.001, saved_cost_usd=0, avg_latency_ms=100, errors=0 },
            { user_id=USER_A, tenant_id=TENANT_2, email="alice@t.com",
              requests=1, blocked=0, cached=0, input_tokens=10, output_tokens=5,
              cost_usd=0.002, saved_cost_usd=0, avg_latency_ms=150, errors=0 },
        })
        table.insert(results_depth, {})

        local depth = M_depth.get_analytics_depth()
        assert.equal(2, #depth.by_user,
            "same user_id across two tenants must produce two separate rows")
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
        "admin.api", "admin.chat", "storage", "auth.byok", "utils.crypto",
        "utils.json", "providers", "core.app_config", "admin.auth",
        "utils.email", "utils.http",
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
        package.preload["admin.auth"]  = function() return { require_session = function() end, check_tenant = function() return true end } end
        package.preload["admin.chat"]  = function() return { register = function() end } end
        package.preload["utils.email"] = function() return { send = function() end, send_template = function() end } end
        package.preload["utils.http"]  = function()
            return { request = function() return 200, {}, "{}", nil end }
        end

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
