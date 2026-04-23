-- tests/unit/test_admin_auth_session.lua — unit tests for src/admin/auth.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_auth_session.lua
--
-- Coverage:
--   1. require_session: no cookie → 401
--   2. require_session: invalid JWT → 401
--   3. require_session: soft-deleted user → 401
--   4. require_session: valid JWT + live user → populates ctx.admin_user with DB values
--   5. require_session: role change in DB overrides JWT payload
--   6. check_tenant: admin role always passes
--   7. check_tenant: non-admin matching tenant passes
--   8. check_tenant: non-admin different tenant returns false

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

local _ngx_time  = 1700000000
local _printed   = nil
local _exited    = nil
local _status    = 200
local _headers   = {}
local _cookie    = ""

_G.ngx = {
    time            = function() return _ngx_time end,
    now             = function() return _ngx_time + 0.0 end,
    encode_base64   = _real_encode_base64,
    decode_base64   = _real_decode_base64,
    log             = function() end,
    print           = function(s) _printed = s end,
    exit            = function(code) _exited = code; error(code, 0) end,
    status          = _status,
    header          = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var             = { http_cookie = "" },
    ctx             = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

-- JWT secret via env
local _orig_getenv = os.getenv
os.getenv = function(k)
    if k == "AIG_JWT_SECRET" then return "test-secret-for-admin-auth" end
    return _orig_getenv(k)
end

local _users_db = {}
local _storage_mock = {
    get_user = function(id) return _users_db[id], nil end,
}

for _, n in ipairs({"admin.auth","utils.jwt","storage","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.loaded["storage"]          = _storage_mock
package.preload["core.app_config"] = function() return {} end

local auth = require("admin.auth")
local jwt  = require("utils.jwt")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function reset()
    _printed = nil
    _exited  = nil
    _status  = 200
    _headers = {}
    _G.ngx.status  = 200
    _G.ngx.ctx     = {}
    _G.ngx.var.http_cookie = ""
    _users_db = {}
end

local function make_jwt(payload)
    return jwt.sign(payload)
end

local function set_cookie(token)
    _G.ngx.var.http_cookie = "aig_admin=" .. token
end

local function make_user(id, role, tenant_id, deleted_at)
    _users_db[id] = { id=id, email=id.."@test.com", role=role,
                      tenant_id=tenant_id, deleted_at=deleted_at }
    return _users_db[id]
end

-- ============================================================================
-- 1. No cookie
-- ============================================================================

describe("admin.auth.require_session: no cookie", function()

    it("returns 401 when no cookie is set", function()
        reset()
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
        assert.equal(401, _G.ngx.status)
    end)

    it("response body mentions unauthenticated", function()
        reset()
        pcall(auth.require_session)
        assert.not_nil(_printed)
        assert(_printed:find("unauthenticated") or _printed:find("error"),
            "body should mention error: " .. tostring(_printed))
    end)

end)

-- ============================================================================
-- 2. Invalid JWT
-- ============================================================================

describe("admin.auth.require_session: invalid JWT", function()

    it("returns 401 for a malformed JWT string", function()
        reset()
        set_cookie("not.a.valid.jwt")
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
    end)

    it("returns 401 for an expired JWT", function()
        reset()
        local expired = make_jwt({
            sub = "u-001", email = "u@t.com", role = "admin",
            iat = _ngx_time - 7200, exp = _ngx_time - 3600,
        })
        set_cookie(expired)
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
    end)

    it("returns 401 for a JWT signed with a different secret", function()
        reset()
        -- Sign with wrong secret
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return "wrong-secret" end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        local bad_jwt = require("utils.jwt")
        local tampered = bad_jwt.sign({ sub="u-002", role="admin",
                                        iat=_ngx_time, exp=_ngx_time+3600 })
        -- Restore correct secret
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return "test-secret-for-admin-auth" end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        jwt = require("utils.jwt")

        set_cookie(tampered)
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
    end)

end)

-- ============================================================================
-- 3. Soft-deleted user
-- ============================================================================

describe("admin.auth.require_session: soft-deleted user", function()

    it("returns 401 when user.deleted_at is set", function()
        reset()
        make_user("u-del", "admin", "tn-1", 1699000000)  -- deleted
        local token = make_jwt({ sub="u-del", role="admin",
                                 iat=_ngx_time, exp=_ngx_time+3600 })
        set_cookie(token)
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
    end)

    it("returns 401 when user does not exist in DB", function()
        reset()
        -- no user seeded
        local token = make_jwt({ sub="ghost-user", role="admin",
                                 iat=_ngx_time, exp=_ngx_time+3600 })
        set_cookie(token)
        local ok, err = pcall(auth.require_session)
        assert.is_false(ok)
        assert.equal(401, tonumber(tostring(err)))
    end)

end)

-- ============================================================================
-- 4. Valid session — populates ctx.admin_user from DB
-- ============================================================================

describe("admin.auth.require_session: valid session", function()

    it("populates ctx.admin_user with id, email, role, tenant_id from DB", function()
        reset()
        make_user("u-valid", "admin", "tn-valid")
        local token = make_jwt({ sub="u-valid", role="admin",
                                 iat=_ngx_time, exp=_ngx_time+3600 })
        set_cookie(token)
        local ok = pcall(auth.require_session)
        assert.is_true(ok, "valid session must not raise")
        local u = _G.ngx.ctx.admin_user
        assert.not_nil(u, "ctx.admin_user must be set")
        assert.equal("u-valid",      u.id)
        assert.equal("u-valid@test.com", u.email)
        assert.equal("admin",        u.role)
        assert.equal("tn-valid",     u.tenant_id)
    end)

    it("uses DB role, not JWT payload role (live re-validation)", function()
        reset()
        -- DB has the user as "member", but JWT says "admin"
        make_user("u-rolechange", "member", "tn-1")
        local token = make_jwt({ sub="u-rolechange", role="admin",
                                 iat=_ngx_time, exp=_ngx_time+3600 })
        set_cookie(token)
        local ok = pcall(auth.require_session)
        assert.is_true(ok)
        assert.equal("member", _G.ngx.ctx.admin_user.role,
            "role must come from DB, not JWT payload")
    end)

end)

-- ============================================================================
-- 5. check_tenant
-- ============================================================================

describe("admin.auth.check_tenant", function()

    it("returns true for admin role regardless of tenant_id", function()
        reset()
        _G.ngx.ctx.admin_user = { id="u1", role="admin", tenant_id="tn-a" }
        assert.is_true(auth.check_tenant("tn-b"))
        assert.is_true(auth.check_tenant("tn-a"))
        assert.is_true(auth.check_tenant("any-tenant"))
    end)

    it("returns true for non-admin user on their own tenant", function()
        reset()
        _G.ngx.ctx.admin_user = { id="u2", role="member", tenant_id="tn-mine" }
        assert.is_true(auth.check_tenant("tn-mine"))
    end)

    it("returns false for non-admin user on a different tenant", function()
        reset()
        _G.ngx.ctx.admin_user = { id="u3", role="member", tenant_id="tn-mine" }
        assert.is_false(auth.check_tenant("tn-other"))
    end)

    it("returns false when no admin_user in ctx", function()
        reset()
        _G.ngx.ctx.admin_user = nil
        assert.is_false(auth.check_tenant("tn-any"))
    end)

    it("tenant_admin role follows the same tenant scoping as member", function()
        reset()
        _G.ngx.ctx.admin_user = { id="u4", role="tenant_admin", tenant_id="tn-own" }
        assert.is_true(auth.check_tenant("tn-own"))
        assert.is_false(auth.check_tenant("tn-other"))
    end)

end)
