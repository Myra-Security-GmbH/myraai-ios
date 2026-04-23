-- tests/unit/test_middleware_auth.lua — unit tests for src/middleware/auth.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_auth.lua
--
-- Coverage:
--   1. extract_token: x-aig-token, Bearer, x-api-key, none → UNAUTHORIZED
--   2. auth_required=false: middleware skips
--   3. Token expiry check
--   4. Viewer role rejection
--   5. User soft-delete check
--   6. Playground token: sets trace_id, pcall protects trace creation
--   7. User-bound token: flows user_id / user_role to ctx

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ---------------------------------------------------------------------------
-- ngx stub
-- ---------------------------------------------------------------------------
local _log_calls = {}
local _exited    = nil
local _printed   = nil
local _headers   = {}

local _http_x_aig_token    = nil
local _http_authorization  = nil
local _http_x_api_key      = nil
local _ngx_time            = 1700000000

_G.ngx = {
    time   = function() return _ngx_time end,
    log    = function(_, ...) _log_calls[#_log_calls + 1] = table.concat({...}) end,
    exit   = function(code) _exited = code; error(code) end,
    print  = function(s) _printed = s end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v)
    end }),
    var    = {},
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    timer  = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
}

-- Helpers to set header vars
local function set_token_header(tok)  _G.ngx.var.http_x_aig_token   = tok  end
local function set_bearer(val)        _G.ngx.var.http_authorization  = val  end
local function set_api_key(val)       _G.ngx.var.http_x_api_key      = val  end
local function clear_headers()
    _G.ngx.var.http_x_aig_token   = nil
    _G.ngx.var.http_authorization  = nil
    _G.ngx.var.http_x_api_key      = nil
end

-- ---------------------------------------------------------------------------
-- Module stubs
-- ---------------------------------------------------------------------------

local _storage_tokens = {}  -- hash → token_row
local _storage_users  = {}  -- user_id → user_row
local _trace_created  = {}  -- trace ids created
local _trace_should_fail = false

local storage_mock = {
    get_auth_token = function(gw_id, hash)
        return _storage_tokens[hash], nil
    end,
    get_user = function(user_id)
        return _storage_users[user_id], nil
    end,
    create_playground_trace = function(trace_id, gw_id, ...)
        if _trace_should_fail then error("trace store failure") end
        _trace_created[#_trace_created + 1] = trace_id
    end,
}

local function clear_storage()
    _storage_tokens = {}
    _storage_users  = {}
    _trace_created  = {}
    _trace_should_fail = false
end

for _, n in ipairs({"middleware.auth","utils.crypto","storage","core.errors","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.loaded["storage"]          = storage_mock
package.preload["core.app_config"] = function() return {} end

-- Deterministic sha256_hex: "HASH:<input>"
package.preload["utils.crypto"] = function()
    return { sha256_hex = function(s) return "HASH:" .. s end }
end

-- errors.send captures code and calls ngx.exit
package.preload["core.errors"] = function()
    return {
        codes = {},
        send = function(code, detail)
            _exited = code
            error(code, 0)  -- level 0: no file:line prefix
        end,
    }
end

local auth = require("middleware.auth")

-- ---------------------------------------------------------------------------
-- Reset helper
-- ---------------------------------------------------------------------------
local function reset(ctx_override)
    _log_calls = {}
    _exited    = nil
    _printed   = nil
    _headers   = {}
    _G.ngx.status = 200
    _G.ngx.ctx = ctx_override or {}
    clear_headers()
    clear_storage()
end

local function make_ctx(gw_cfg)
    return {
        gateway_id     = "gw-001",
        gateway_config = gw_cfg or { auth_required = true },
        request_id     = "req-abc",
    }
end

-- Add a token row to the mock storage (hash = "HASH:<raw_token>")
local function add_token(raw_token, row)
    _storage_tokens["HASH:" .. raw_token] = row
end
-- Add a user row
local function add_user(user_id, row)
    _storage_users[user_id] = row
end

-- ============================================================================
-- 1. Token extraction
-- ============================================================================

describe("middleware.auth: token extraction", function()

    it("accepts token from x-aig-token header", function()
        reset()
        local ctx = make_ctx()
        set_token_header("mytoken123")
        add_token("mytoken123", { id="t1", label="ci", expires_at=nil,
                                  budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok, "should not raise when token is valid")
        assert.equal("t1", ctx.token_id)
    end)

    it("accepts token from Authorization: Bearer header", function()
        reset()
        local ctx = make_ctx()
        set_bearer("Bearer bearertoken456")
        add_token("bearertoken456", { id="t2", label="sdk", expires_at=nil,
                                      budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("t2", ctx.token_id)
    end)

    it("accepts Bearer with lowercase 'bearer'", function()
        reset()
        local ctx = make_ctx()
        set_bearer("bearer lowertoken")
        add_token("lowertoken", { id="t3", label="api", expires_at=nil,
                                  budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("t3", ctx.token_id)
    end)

    it("accepts token from x-api-key header (Anthropic SDK compat)", function()
        reset()
        local ctx = make_ctx()
        set_api_key("anthtoken789")
        add_token("anthtoken789", { id="t4", label="anth", expires_at=nil,
                                    budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("t4", ctx.token_id)
    end)

    it("prefers x-aig-token over Authorization when both present", function()
        reset()
        local ctx = make_ctx()
        set_token_header("primary")
        set_bearer("Bearer secondary")
        add_token("primary",   { id="t5a", label="a", expires_at=nil, budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        add_token("secondary", { id="t5b", label="b", expires_at=nil, budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("t5a", ctx.token_id, "x-aig-token must win over Bearer")
    end)

    it("sends UNAUTHORIZED when no token is present", function()
        reset()
        local ctx = make_ctx()
        local ok, err = pcall(auth.run, ctx)
        assert.is_false(ok)
        assert.equal("UNAUTHORIZED", tostring(err))
    end)

    it("sends UNAUTHORIZED when token is not in storage (unknown token)", function()
        reset()
        local ctx = make_ctx()
        set_token_header("unknown")
        -- no matching row in storage
        local ok, err = pcall(auth.run, ctx)
        assert.is_false(ok)
        assert.equal("UNAUTHORIZED", tostring(err))
    end)

end)

-- ============================================================================
-- 2. auth_required=false
-- ============================================================================

describe("middleware.auth: auth_required=false skips validation", function()

    it("returns without error when auth_required=false, even with no token", function()
        reset()
        local ctx = make_ctx({ auth_required = false })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok, "must not raise when auth_required=false")
        assert.is_nil(ctx.token_id, "no token_id set when auth skipped")
    end)

end)

-- ============================================================================
-- 3. Token expiry
-- ============================================================================

describe("middleware.auth: token expiry", function()

    it("accepts a token whose expires_at is in the future", function()
        reset()
        local ctx = make_ctx()
        set_token_header("validtok")
        add_token("validtok", { id="tv", label="x", expires_at=_ngx_time + 3600,
                                budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("tv", ctx.token_id)
    end)

    it("accepts a token with nil expires_at (never expires)", function()
        reset()
        local ctx = make_ctx()
        set_token_header("notok")
        add_token("notok", { id="tn", label="y", expires_at=nil,
                             budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("tn", ctx.token_id)
    end)

    it("sends UNAUTHORIZED for an expired token", function()
        reset()
        local ctx = make_ctx()
        set_token_header("expired")
        add_token("expired", { id="te", label="z", expires_at=_ngx_time - 1,
                               budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok, err = pcall(auth.run, ctx)
        assert.is_false(ok)
        assert.equal("UNAUTHORIZED", tostring(err))
    end)

end)

-- ============================================================================
-- 4. Context fields set on valid token
-- ============================================================================

describe("middleware.auth: ctx fields from token row", function()

    it("sets token_id, token_label, token_budget_usd, budget_period, token_rate_limit", function()
        reset()
        local ctx = make_ctx()
        set_token_header("richtoken")
        add_token("richtoken", {
            id             = "tok-rich",
            label          = "dev-key",
            expires_at     = nil,
            budget_usd     = 5.0,
            budget_period  = "weekly",
            rate_limit     = '{"requests":50,"window_sec":60}',
            user_id        = nil,
        })
        pcall(auth.run, ctx)
        assert.equal("tok-rich",  ctx.token_id)
        assert.equal("dev-key",   ctx.token_label)
        assert.equal(5.0,         ctx.token_budget_usd)
        assert.equal("weekly",    ctx.token_budget_period)
        assert.not_nil(ctx.token_rate_limit)
    end)

    it("budget_period defaults to 'monthly' when nil in token row", function()
        reset()
        local ctx = make_ctx()
        set_token_header("notok")
        add_token("notok", { id="t-def", label="x", expires_at=nil,
                             budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        pcall(auth.run, ctx)
        assert.equal("monthly", ctx.token_budget_period)
    end)

end)

-- ============================================================================
-- 5. Viewer role rejection
-- ============================================================================

describe("middleware.auth: viewer role rejection", function()

    it("sends FORBIDDEN when user has viewer role", function()
        reset()
        local ctx = make_ctx()
        set_token_header("viewertok")
        add_token("viewertok", { id="tv2", label="v", expires_at=nil,
                                 budget_usd=nil, budget_period=nil, rate_limit=nil,
                                 user_id="user-viewer" })
        add_user("user-viewer", { id="user-viewer", role="viewer", deleted_at=nil })
        local ok, err = pcall(auth.run, ctx)
        assert.is_false(ok)
        assert.equal("FORBIDDEN", tostring(err))
    end)

    it("allows member and admin roles", function()
        for _, role in ipairs({"member", "admin", "tenant_admin"}) do
            reset()
            local ctx = make_ctx()
            set_token_header("tok-" .. role)
            add_token("tok-" .. role, { id="t-" .. role, label="x", expires_at=nil,
                                        budget_usd=nil, budget_period=nil, rate_limit=nil,
                                        user_id="user-" .. role })
            add_user("user-" .. role, { id="user-" .. role, role=role, deleted_at=nil })
            local ok = pcall(auth.run, ctx)
            assert.is_true(ok, role .. " should be allowed")
            assert.equal("user-" .. role, ctx.user_id)
            assert.equal(role, ctx.user_role)
        end
    end)

end)

-- ============================================================================
-- 6. User soft-delete
-- ============================================================================

describe("middleware.auth: soft-deleted user", function()

    it("sends UNAUTHORIZED when user.deleted_at is set", function()
        reset()
        local ctx = make_ctx()
        set_token_header("deletedtok")
        add_token("deletedtok", { id="td", label="x", expires_at=nil,
                                  budget_usd=nil, budget_period=nil, rate_limit=nil,
                                  user_id="user-deleted" })
        add_user("user-deleted", { id="user-deleted", role="member", deleted_at=1700000000 })
        local ok, err = pcall(auth.run, ctx)
        assert.is_false(ok)
        assert.equal("UNAUTHORIZED", tostring(err))
    end)

end)

-- ============================================================================
-- 7. Playground token
-- ============================================================================

describe("middleware.auth: playground token", function()

    it("sets ctx.trace_id to ctx.request_id for playground tokens", function()
        reset()
        local ctx = make_ctx()
        ctx.request_id = "req-play-001"
        set_token_header("playtok")
        add_token("playtok", { id="tp", label="playground", expires_at=nil,
                               budget_usd=nil, budget_period=nil, rate_limit=nil, user_id="user-play" })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok)
        assert.equal("req-play-001", ctx.trace_id)
        assert.equal(0, ctx.trace_seq)
    end)

    it("playground trace creation failure (pcall) does not abort the request", function()
        reset()
        _trace_should_fail = true
        local ctx = make_ctx()
        ctx.request_id = "req-fail"
        set_token_header("playtok2")
        add_token("playtok2", { id="tp2", label="playground", expires_at=nil,
                                budget_usd=nil, budget_period=nil, rate_limit=nil, user_id=nil })
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok, "trace creation failure must not abort the request")
    end)

    it("playground token still records user_id for attribution (no role check)", function()
        reset()
        local ctx = make_ctx()
        ctx.request_id = "req-attr"
        set_token_header("playtok3")
        -- user exists but with viewer role — playground skips role check
        add_token("playtok3", { id="tp3", label="playground", expires_at=nil,
                                budget_usd=nil, budget_period=nil, rate_limit=nil, user_id="user-view2" })
        -- user is NOT added to _storage_users — playground token bypasses user lookup
        local ok = pcall(auth.run, ctx)
        assert.is_true(ok, "playground token with viewer-role user must not be rejected")
        assert.equal("user-view2", ctx.user_id)
    end)

end)
