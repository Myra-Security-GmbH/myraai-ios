-- tests/unit/test_jwt.lua
-- Unit tests for src/utils/jwt.lua — HS256 sign/verify.
-- Run with: resty tests/runner.lua tests/unit/test_jwt.lua

-- ---------------------------------------------------------------------------
-- ngx stub
-- ---------------------------------------------------------------------------

local _ngx_time = 1700000000

-- Save the real base64 functions; fall back to require("ngx") in case a prior
-- test replaced _G.ngx with a stub that doesn't include encode_base64.
local _real_encode_base64 = (_G.ngx and _G.ngx.encode_base64) or require("ngx").encode_base64
local _real_decode_base64 = (_G.ngx and _G.ngx.decode_base64) or require("ngx").decode_base64

_G.ngx = {
    time          = function() return _ngx_time end,
    encode_base64 = _real_encode_base64,
    decode_base64 = _real_decode_base64,
    log           = function() end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "/home/sas/work/ai-gateway/src/?.lua;" ..
                "/home/sas/work/ai-gateway/src/?/init.lua;" ..
                package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- Stub core.app_config before jwt.lua loads it (prevents real gateway.lua from
-- overriding the jwt_secret during get_secret() caching).
package.loaded["core.app_config"]  = nil
package.preload["core.app_config"] = function() return {} end

-- Force jwt.lua to reload cleanly
package.loaded["utils.jwt"] = nil

-- Override AIG_JWT_SECRET for deterministic tests
local _orig_getenv = os.getenv
local _test_secret = "test-secret-do-not-use-in-prod"
os.getenv = function(k)
    if k == "AIG_JWT_SECRET" then return _test_secret end
    return _orig_getenv(k)
end

local jwt = require("utils.jwt")

-- ============================================================================
-- Helper: make payload with given exp delta (seconds from now)
-- ============================================================================

local function make_payload(exp_delta, extra)
    local p = {
        sub   = "user-abc",
        email = "admin@example.com",
        role  = "admin",
        org   = nil,
        iat   = _ngx_time,
        exp   = _ngx_time + (exp_delta or 3600),
    }
    if extra then
        for k, v in pairs(extra) do p[k] = v end
    end
    return p
end

-- ============================================================================
-- sign / verify round-trip
-- ============================================================================

describe("jwt.sign + jwt.verify round-trip", function()

    it("signs a payload and verifies it successfully", function()
        local token = jwt.sign(make_payload())
        assert.not_nil(token)
        assert.equal("string", type(token))

        local payload, err = jwt.verify(token)
        assert.is_nil(err)
        assert.not_nil(payload)
        assert.equal("user-abc",          payload.sub)
        assert.equal("admin@example.com", payload.email)
        assert.equal("admin",             payload.role)
    end)

    it("token has three dot-separated parts", function()
        local token = jwt.sign(make_payload())
        local parts = {}
        for p in token:gmatch("[^%.]+") do parts[#parts + 1] = p end
        assert.equal(3, #parts)
    end)

    it("header encodes alg=HS256 and typ=JWT", function()
        local token  = jwt.sign(make_payload())
        local header_b64 = token:match("^([^%.]+)")
        local pad = (4 - #header_b64 % 4) % 4
        local b64  = (header_b64 .. string.rep("=", pad)):gsub("-", "+"):gsub("_", "/")
        local json = require("cjson.safe")
        local hdr  = json.decode(ngx.decode_base64(b64))
        assert.equal("HS256", hdr.alg)
        assert.equal("JWT",   hdr.typ)
    end)

    it("payload claims survive encode/decode", function()
        local orig  = make_payload(7200, { org = "org-123" })
        local token = jwt.sign(orig)
        local p     = jwt.verify(token)
        assert.equal(orig.sub,   p.sub)
        assert.equal(orig.email, p.email)
        assert.equal(orig.role,  p.role)
        assert.equal(orig.org,   p.org)
        assert.equal(orig.exp,   p.exp)
    end)

end)

-- ============================================================================
-- expired / not-yet-valid tokens
-- ============================================================================

describe("jwt.verify: time-based claims", function()

    it("returns 'token expired' for a token with exp in the past", function()
        local token = jwt.sign(make_payload(-1))   -- already expired
        local payload, err = jwt.verify(token)
        assert.is_nil(payload)
        assert.equal("token expired", err)
    end)

    it("verifies successfully when exp == now + 1", function()
        local token = jwt.sign(make_payload(1))
        local payload, err = jwt.verify(token)
        assert.is_nil(err)
        assert.not_nil(payload)
    end)

    it("returns 'token not yet valid' for a token with nbf in the future", function()
        local token = jwt.sign(make_payload(3600, { nbf = _ngx_time + 60 }))
        local payload, err = jwt.verify(token)
        assert.is_nil(payload)
        assert.equal("token not yet valid", err)
    end)

end)

-- ============================================================================
-- signature tampering
-- ============================================================================

describe("jwt.verify: tampered signature", function()

    it("rejects a token with a flipped byte in the signature", function()
        local token = jwt.sign(make_payload())
        -- Replace last character of signature with a different one
        local tampered = token:sub(1, -2) .. (token:sub(-1) == "A" and "B" or "A")
        local payload, err = jwt.verify(tampered)
        assert.is_nil(payload)
        assert.not_nil(err)
        -- err is either "invalid signature" or "base64 decode failed"
        assert(err == "invalid signature" or err == "base64 decode failed",
               "unexpected err: " .. tostring(err))
    end)

    it("rejects a token whose payload has been swapped with a different payload", function()
        local token1 = jwt.sign(make_payload(3600, { sub = "user-1" }))
        local token2 = jwt.sign(make_payload(3600, { sub = "user-2" }))

        -- Swap the body segment of token1 with token2's body
        local parts1 = {}
        for p in token1:gmatch("[^%.]+") do parts1[#parts1+1] = p end
        local parts2 = {}
        for p in token2:gmatch("[^%.]+") do parts2[#parts2+1] = p end

        local spliced = parts1[1] .. "." .. parts2[2] .. "." .. parts1[3]
        local payload, err = jwt.verify(spliced)
        assert.is_nil(payload)
        assert.equal("invalid signature", err)
    end)

    it("rejects a token signed with a different secret", function()
        -- Temporarily change secret
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return "other-secret" end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        local jwt2 = require("utils.jwt")
        local token = jwt2.sign(make_payload())

        -- Restore original secret and reload
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return _test_secret end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        jwt = require("utils.jwt")

        local payload, err = jwt.verify(token)
        assert.is_nil(payload)
        assert.equal("invalid signature", err)
    end)

end)

-- ============================================================================
-- malformed tokens
-- ============================================================================

describe("jwt.verify: malformed input", function()

    it("returns 'missing token' for nil input", function()
        local payload, err = jwt.verify(nil)
        assert.is_nil(payload)
        assert.equal("missing token", err)
    end)

    it("returns 'malformed token' for a token with only two parts", function()
        local payload, err = jwt.verify("aaa.bbb")
        assert.is_nil(payload)
        assert.equal("malformed token", err)
    end)

    it("returns 'malformed token' for an empty string", function()
        local payload, err = jwt.verify("")
        assert.is_nil(payload)
        assert.equal("malformed token", err)
    end)

    it("handles a valid-looking token with non-JSON body gracefully", function()
        local bad_body = ngx.encode_base64("not-json"):gsub("+","-"):gsub("/","_"):gsub("=+$","")
        local token = jwt.sign(make_payload())
        local parts = {}
        for p in token:gmatch("[^%.]+") do parts[#parts+1] = p end
        -- Replace body with non-JSON, keep original sig (will fail sig check first)
        local spliced = parts[1] .. "." .. bad_body .. "." .. parts[3]
        local payload, err = jwt.verify(spliced)
        assert.is_nil(payload)
        assert.not_nil(err)
    end)

end)

-- ============================================================================
-- Finding 18 — missing AIG_JWT_SECRET must raise, not fall back
-- ============================================================================

describe("jwt: missing AIG_JWT_SECRET raises an error (Finding 18)", function()

    it("sign() raises when AIG_JWT_SECRET is nil", function()
        -- Unset the secret and force module reload so get_secret() runs fresh.
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return nil end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        package.preload["core.app_config"] = function() return {} end  -- no jwt_secret

        local jwt_no_secret = require("utils.jwt")
        local ok, err = pcall(jwt_no_secret.sign, make_payload())
        assert.is_false(ok, "sign() should raise when secret is missing")
        assert.not_nil(err)
        -- Error message must mention the missing secret, not produce a token
        assert(tostring(err):find("AIG_JWT_SECRET") or tostring(err):find("not configured"),
            "error should mention AIG_JWT_SECRET, got: " .. tostring(err))

        -- Restore for subsequent tests
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return _test_secret end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        jwt = require("utils.jwt")
    end)

    it("sign() raises when AIG_JWT_SECRET is an empty string", function()
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return "" end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        package.preload["core.app_config"] = function() return {} end

        local jwt_empty = require("utils.jwt")
        local ok, err = pcall(jwt_empty.sign, make_payload())
        assert.is_false(ok, "sign() should raise when secret is empty string")

        -- Restore
        os.getenv = function(k)
            if k == "AIG_JWT_SECRET" then return _test_secret end
            return _orig_getenv(k)
        end
        package.loaded["utils.jwt"] = nil
        jwt = require("utils.jwt")
    end)

end)
