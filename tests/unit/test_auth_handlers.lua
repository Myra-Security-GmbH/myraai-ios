-- tests/unit/test_auth_handlers.lua
-- Unit tests for src/admin/auth_handlers.lua
-- Covers: OTP request/verify, /me, /logout, error paths.
-- Run with: resty tests/runner.lua tests/unit/test_auth_handlers.lua

-- ---------------------------------------------------------------------------
-- ngx stub
-- ---------------------------------------------------------------------------

local _ngx_time = 1700000000

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

local _ngx_printed  = nil
local _ngx_cookie   = ""
local _ngx_headers  = {}
local _ngx_status   = 200
local _ngx_method   = "POST"
local _ngx_uri      = "/admin/auth/otp/request"
local _ngx_body_raw = "{}"

_G.ngx = {
    time            = function() return _ngx_time end,
    now             = function() return _ngx_time + 0.0 end,
    encode_base64   = _real_encode_base64,
    decode_base64   = _real_decode_base64,
    log             = function() end,
    print           = function(s) _ngx_printed = s end,
    exit            = function(code) error("ngx.exit:" .. tostring(code)) end,
    redirect        = function(url, code) error("ngx.redirect:" .. tostring(url)) end,
    escape_uri      = function(s) return s end,   -- simplification for tests
    req = {
        read_body     = function() end,
        get_body_data = function() return _ngx_body_raw end,
        get_method    = function() return _ngx_method end,
        get_uri_args  = function() return {} end,
    },
    var    = { remote_addr = "127.0.0.1", uri = _ngx_uri, http_origin = "http://localhost:5173",
               http_cookie = "" },
    header = setmetatable({}, {
        __newindex = function(t, k, v) _ngx_headers[k] = v; rawset(t, k, v) end,
    }),
    status = _ngx_status,
    ctx    = {},
    shared = {
        aig_ratelimit = (function()
            local store = {}
            return {
                set    = function(_, k, v, _ttl) store[k] = v end,
                get    = function(_, k) return store[k] end,
                delete = function(_, k) store[k] = nil end,
            }
        end)(),
    },
    ERR = 0, WARN = 1, INFO = 2,
    -- Execute timer callbacks synchronously so email sends are captured in tests.
    timer = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
}

package.path  = "/home/sas/work/ai-gateway/src/?.lua;" ..
                "/home/sas/work/ai-gateway/src/?/init.lua;" ..
                package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- Stub core.app_config to avoid loading the real gateway.lua
package.loaded["core.app_config"]  = nil
package.preload["core.app_config"] = function()
    return {
        auth = {
            jwt_secret      = "test-secret-for-auth-handlers",
            jwt_expiry_secs = 3600,
            otp_expiry_secs = 900,
            otp_from_email  = "noreply@test.local",
        },
    }
end

-- ---------------------------------------------------------------------------
-- resty.random stub — deterministic for reproducible tests
-- ---------------------------------------------------------------------------

-- 4-byte value for OTP generation: 0x05F5E100 = 99999744
-- code = 99999744 % 900000 + 100000 = 99744 + 100000 = 199744
local _otp_bytes  = string.char(0x05, 0xF5, 0xE1, 0x00)
-- 16-byte value for UUID generation (deterministic)
local _uuid_bytes = string.char(0x01,0x02,0x03,0x04, 0x05,0x06,0x07,0x08,
                                0x09,0x0a,0x0b,0x0c, 0x0d,0x0e,0x0f,0x10)

local _random_call_count = 0

package.preload["resty.random"] = function()
    return {
        bytes = function(n, _strong)
            _random_call_count = _random_call_count + 1
            -- UUID requests 16, OTP requests 4
            if n == 16 then
                -- Vary bytes to make unique UUIDs per call
                local base = _uuid_bytes
                local result = {}
                for i = 1, 16 do
                    result[i] = string.char(((base:byte(i) + _random_call_count - 1) % 255) + 1)
                end
                return table.concat(result)
            end
            return _otp_bytes:sub(1, n)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- In-memory storage (replaces storage.sqlite — no lsqlite3 dependency)
-- ---------------------------------------------------------------------------

local _users_db   = {}
local _otps_db    = {}
local _user_id_n  = 0

local storage = {}

function storage.insert_user(tenant_id, email, name, role)
    for _, u in ipairs(_users_db) do
        if u.email == email and not u.deleted_at then
            return nil, "email already registered"
        end
    end
    _user_id_n = _user_id_n + 1
    local id = string.format("user-%04d", _user_id_n)
    _users_db[#_users_db + 1] = {
        id = id, tenant_id = tenant_id, email = email,
        name = name, role = role or "admin", deleted_at = nil,
    }
    return id, nil
end

function storage.find_admin_user_by_email(email)
    for _, u in ipairs(_users_db) do
        if u.email == email and not u.deleted_at then return u end
    end
    return nil
end

function storage.insert_email_otp(id, email, code_hash, expires_at, ip_addr)
    local fresh = {}
    for _, o in ipairs(_otps_db) do
        if o.email ~= email or (not o.used_at and o.expires_at >= ngx.time()) then
            fresh[#fresh + 1] = o
        end
    end
    _otps_db = fresh
    _otps_db[#_otps_db + 1] = {
        id=id, email=email, code_hash=code_hash,
        expires_at=expires_at, ip_addr=ip_addr, used_at=nil,
    }
    return nil
end

function storage.consume_email_otp(email, code_hash)
    local now = os.time()
    for _, o in ipairs(_otps_db) do
        if o.email == email and o.code_hash == code_hash
           and not o.used_at and o.expires_at > now then
            o.used_at = now
            return nil
        end
    end
    return "invalid or expired code"
end

function storage.touch_last_login()  end
function storage.upsert_oauth_link() end

package.loaded["storage"]        = nil
package.loaded["storage.sqlite"] = nil
package.loaded["storage"]        = storage

-- ---------------------------------------------------------------------------
-- email.lua stub (capture sent emails)
-- ---------------------------------------------------------------------------

local _sent_emails = {}
package.preload["utils.email"] = function()
    return {
        send = function(to, subject, body)
            _sent_emails[#_sent_emails + 1] = { to = to, subject = subject, body = body }
            return nil   -- no error
        end,
        send_template = function(to, template, vars)
            _sent_emails[#_sent_emails + 1] = { to = to, template = template, vars = vars }
            return nil   -- no error
        end,
    }
end
package.loaded["utils.email"] = nil

-- ---------------------------------------------------------------------------
-- Force reload of jwt and auth_handlers with our stubs in place
-- ---------------------------------------------------------------------------

for _, m in ipairs({ "utils.jwt", "utils.crypto", "admin.auth_handlers", "admin.auth", "utils.uuid" }) do
    package.loaded[m] = nil
end

local handlers = require("admin.auth_handlers")
local jwt      = require("utils.jwt")
local crypto   = require("utils.crypto")

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

local function reset_ngx(method, uri, body)
    _ngx_printed  = nil
    _ngx_headers  = {}
    _ngx_status   = 200
    ngx.status    = 200
    _ngx_body_raw = body or "{}"
    _ngx_method   = method or "GET"
    _ngx_uri      = uri or "/"
    ngx.var.uri   = _ngx_uri
    ngx.var.http_cookie = _ngx_cookie
    -- Reset header table metatable tracking
    ngx.header = setmetatable({}, {
        __newindex = function(t, k, v) _ngx_headers[k] = v; rawset(t, k, v) end,
    })
    ngx.ctx = {}
end

local function dispatch(method, uri, body)
    reset_ngx(method, uri, body)
    ngx.req.get_method    = function() return method end
    ngx.var.uri           = uri
    ngx.req.get_body_data = function() return body end
    local ok, err = pcall(function() handlers.handle() end)
    return ok, err, _ngx_printed and require("cjson.safe").decode(_ngx_printed) or nil
end

local function insert_admin_user(email, role)
    -- insert_user(tenant_id, email, name, role) — nil tenant_id for admin users
    local id, err = storage.insert_user(nil, email, "Test Admin", role or "admin")
    assert(id, "failed to insert admin user: " .. tostring(err))
    return id
end

local function cleanup_user(email)
    local new = {}
    for _, u in ipairs(_users_db) do
        if u.email ~= email then new[#new + 1] = u end
    end
    _users_db = new
end

local function cleanup_otps(email)
    if email then
        local new = {}
        for _, o in ipairs(_otps_db) do
            if o.email ~= email then new[#new + 1] = o end
        end
        _otps_db = new
    else
        _otps_db = {}
    end
end

-- Compute expected OTP code from the fixed random bytes stub:
-- bytes = {0x05, 0xF5, 0xE1, 0x00}, n = 0x05F5E100 = 99999744
-- code = 99999744 % 900000 + 100000 = 99744 + 100000 = 199744
local EXPECTED_CODE = tostring(99744 + 100000)

-- ============================================================================
-- GET /admin/auth/me
-- ============================================================================

describe("GET /admin/auth/me", function()

    it("returns 401 when no cookie is present", function()
        reset_ngx("GET", "/admin/auth/me")
        ngx.var.http_cookie = ""
        local ok, err = pcall(function()
            ngx.req.get_method = function() return "GET" end
            ngx.var.uri = "/admin/auth/me"
            handlers.handle()
        end)
        assert.is_true(ok)
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(401, ngx.status)
        assert.not_nil(body.error)
    end)

    it("returns 401 for a malformed cookie value", function()
        reset_ngx("GET", "/admin/auth/me")
        ngx.var.http_cookie = "aig_admin=not.a.jwt"
        local ok = pcall(function()
            ngx.req.get_method = function() return "GET" end
            ngx.var.uri = "/admin/auth/me"
            handlers.handle()
        end)
        assert.is_true(ok)
        assert.equal(401, ngx.status)
    end)

    it("returns user fields for a valid token", function()
        local token = jwt.sign({
            sub   = "user-xyz",
            email = "admin@example.com",
            role  = "admin",
            tenant = nil,
            iat   = _ngx_time,
            exp   = _ngx_time + 3600,
        })
        reset_ngx("GET", "/admin/auth/me")
        ngx.var.http_cookie = "aig_admin=" .. token
        ngx.req.get_method  = function() return "GET" end
        ngx.var.uri         = "/admin/auth/me"
        handlers.handle()
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(200,                 ngx.status)
        assert.equal("user-xyz",          body.id)
        assert.equal("admin@example.com", body.email)
        assert.equal("admin",             body.role)
    end)

end)

-- ============================================================================
-- POST /admin/auth/logout
-- ============================================================================

describe("POST /admin/auth/logout", function()

    it("clears the session cookie and returns ok=true", function()
        reset_ngx("POST", "/admin/auth/logout", "{}")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/logout"
        ngx.req.get_body_data = function() return "{}" end
        handlers.handle()
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(200,  ngx.status)
        assert.is_true(body.ok)
        -- Cookie should be expired (Max-Age=0)
        local cookie = _ngx_headers["Set-Cookie"] or ""
        assert.match("Max%-Age=0", cookie)
    end)

end)

-- ============================================================================
-- POST /admin/auth/otp/request
-- ============================================================================

describe("POST /admin/auth/otp/request", function()

    local admin_email = "otp_admin@example.com"

    -- Create the admin user once
    before_each(function()
        _sent_emails = {}
    end)

    it("returns 400 when email is missing", function()
        reset_ngx("POST", "/admin/auth/otp/request")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/request"
        ngx.req.get_body_data = function() return '{}' end
        handlers.handle()
        assert.equal(400, ngx.status)
    end)

    it("returns 200 with generic message for unknown email (no enumeration)", function()
        reset_ngx("POST", "/admin/auth/otp/request")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/request"
        ngx.req.get_body_data = function() return '{"email":"nobody@example.com"}' end
        handlers.handle()
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(200, ngx.status)
        assert.not_nil(body.message)
        -- No email should have been sent
        assert.equal(0, #_sent_emails)
    end)

    it("returns 200 and sends email for a known admin email", function()
        insert_admin_user(admin_email)

        reset_ngx("POST", "/admin/auth/otp/request")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/request"
        ngx.req.get_body_data = function() return '{"email":"' .. admin_email .. '"}' end
        handlers.handle()
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(200, ngx.status)
        assert.not_nil(body.message)
        assert.equal(1, #_sent_emails)
        assert.equal(admin_email, _sent_emails[1].to)
    end)

end)

-- ============================================================================
-- POST /admin/auth/otp/verify
-- ============================================================================

describe("POST /admin/auth/otp/verify", function()

    local verify_email = "verify_admin@example.com"
    local verify_user_id

    -- Seed user and OTP before each test
    before_each(function()
        _sent_emails = {}
        -- Hard-delete any leftover user so the UNIQUE constraint doesn't fire
        cleanup_user(verify_email)
        verify_user_id = insert_admin_user(verify_email)

        -- Clean any leftover OTPs from previous tests for this email
        cleanup_otps(verify_email)

        -- Insert a fresh OTP record with real future expiry
        local uuid      = require("utils.uuid")
        local otp_id    = uuid.v4()
        local code_hash = crypto.sha256_hex(EXPECTED_CODE)
        storage.insert_email_otp(otp_id, verify_email, code_hash, os.time() + 900, "127.0.0.1")
    end)

    it("returns 400 when email or code is missing", function()
        reset_ngx("POST", "/admin/auth/otp/verify")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/verify"
        ngx.req.get_body_data = function() return '{"email":"x@x.com"}' end
        handlers.handle()
        assert.equal(400, ngx.status)
    end)

    it("returns 401 for wrong code", function()
        reset_ngx("POST", "/admin/auth/otp/verify")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/verify"
        ngx.req.get_body_data = function()
            return '{"email":"' .. verify_email .. '","code":"000000"}'
        end
        handlers.handle()
        assert.equal(401, ngx.status)
    end)

    it("returns 200 and sets cookie for valid code", function()
        reset_ngx("POST", "/admin/auth/otp/verify")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/verify"
        ngx.req.get_body_data = function()
            return '{"email":"' .. verify_email .. '","code":"' .. EXPECTED_CODE .. '"}'
        end
        handlers.handle()
        local body = require("cjson.safe").decode(_ngx_printed)
        assert.equal(200, ngx.status)
        assert.not_nil(body.user)
        assert.equal(verify_email, body.user.email)
        assert.equal("admin",      body.user.role)
        -- Cookie should be set
        local cookie = _ngx_headers["Set-Cookie"] or ""
        assert.match("aig_admin=", cookie)
        assert.match("HttpOnly",   cookie)
    end)

    it("rejects replay — same code cannot be used twice", function()
        local function do_verify()
            reset_ngx("POST", "/admin/auth/otp/verify")
            ngx.req.get_method    = function() return "POST" end
            ngx.var.uri           = "/admin/auth/otp/verify"
            ngx.req.get_body_data = function()
                return '{"email":"' .. verify_email .. '","code":"' .. EXPECTED_CODE .. '"}'
            end
            handlers.handle()
            return ngx.status
        end

        local first = do_verify()
        assert.equal(200, first)

        local second = do_verify()
        assert.equal(401, second)
    end)

    it("returns 401 for an expired OTP", function()
        -- Insert an already-expired OTP
        local uuid = require("utils.uuid")
        local otp_id    = uuid.v4()
        local code      = "555555"
        local code_hash = crypto.sha256_hex(code)
        storage.insert_email_otp(otp_id, verify_email, code_hash,
                                 os.time() - 1, "127.0.0.1")  -- expired 1 sec ago

        reset_ngx("POST", "/admin/auth/otp/verify")
        ngx.req.get_method    = function() return "POST" end
        ngx.var.uri           = "/admin/auth/otp/verify"
        ngx.req.get_body_data = function()
            return '{"email":"' .. verify_email .. '","code":"' .. code .. '"}'
        end
        handlers.handle()
        assert.equal(401, ngx.status)
    end)

end)

-- ============================================================================
-- 404 for unknown route
-- ============================================================================

describe("unknown route", function()

    it("returns 404 for an unmatched path", function()
        reset_ngx("GET", "/admin/auth/nonexistent")
        ngx.req.get_method = function() return "GET" end
        ngx.var.uri        = "/admin/auth/nonexistent"
        handlers.handle()
        assert.equal(404, ngx.status)
    end)

end)
