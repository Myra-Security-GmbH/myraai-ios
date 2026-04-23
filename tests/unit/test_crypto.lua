-- tests/unit/test_crypto.lua — unit tests for src/utils/crypto.lua
-- Run with: resty tests/runner.lua tests/unit/test_crypto.lua
--
-- Coverage:
--   1. random_bytes / random_hex — length and character set
--   2. sha256_hex — known digest value
--   3. encrypt/decrypt round-trip — new 3-part iv:ct:hmac format
--   4. Authentication — tampered ciphertext or IV rejected
--   5. Tampered HMAC — rejected before decryption
--   6. Legacy 2-part format — still decryptable (backward compat)
--   7. Bad inputs — graceful nil, err returns

-- ---------------------------------------------------------------------------
-- ngx stub (minimal — crypto.lua only calls ngx.log)
-- ---------------------------------------------------------------------------
local _warnings = {}
_G.ngx = {
    log            = function(level, ...) _warnings[#_warnings+1] = table.concat({...}) end,
    encode_base64  = ngx and ngx.encode_base64  or require("ngx").encode_base64,
    decode_base64  = ngx and ngx.decode_base64  or require("ngx").decode_base64,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local function clear()
    for _, n in ipairs({"utils.crypto","resty.sha256","resty.string","resty.aes","resty.random"}) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
    _warnings = {}
end

clear()
local crypto = require("utils.crypto")

-- ============================================================================
-- 1. random_bytes / random_hex
-- ============================================================================

describe("crypto.random_bytes / random_hex", function()

    it("random_bytes(n) returns a string of exactly n bytes", function()
        local b = crypto.random_bytes(16)
        assert.not_nil(b)
        assert.equal(16, #b)
    end)

    it("random_bytes(32) returns 32 bytes", function()
        assert.equal(32, #crypto.random_bytes(32))
    end)

    it("random_hex(16) returns a 32-character lowercase hex string", function()
        local h = crypto.random_hex(16)
        assert.not_nil(h)
        assert.equal(32, #h, "random_hex(16) should produce 32 hex chars (2 per byte)")
        assert(h:match("^[0-9a-f]+$"), "random_hex output must be lowercase hex, got: " .. h)
    end)

    it("random_hex(32) produces 64 hex characters", function()
        assert.equal(64, #crypto.random_hex(32))
    end)

    it("two calls to random_hex(16) produce different values", function()
        local h1 = crypto.random_hex(16)
        local h2 = crypto.random_hex(16)
        assert.not_equal(h1, h2, "CSPRNG should not repeat across calls")
    end)

end)

-- ============================================================================
-- 2. sha256_hex — spot-check against a known digest
-- ============================================================================

describe("crypto.sha256_hex", function()

    it("returns a 64-character lowercase hex string", function()
        local h = crypto.sha256_hex("hello")
        assert.equal(64, #h)
        assert(h:match("^[0-9a-f]+$"), "must be lowercase hex")
    end)

    it("produces the known SHA-256 of 'hello'", function()
        -- echo -n hello | sha256sum → 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        assert.equal(
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            crypto.sha256_hex("hello"))
    end)

    it("empty string has the expected digest", function()
        assert.equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            crypto.sha256_hex(""))
    end)

    it("different inputs produce different digests", function()
        assert.not_equal(crypto.sha256_hex("a"), crypto.sha256_hex("b"))
    end)

end)

-- ============================================================================
-- 3. encrypt / decrypt round-trip — new 3-part format
-- ============================================================================

describe("crypto.encrypt / decrypt round-trip", function()

    it("encrypts a plaintext and decrypts back to the original", function()
        local plaintext  = "super-secret-api-key"
        local passphrase = "test-passphrase-123"
        local ct, err = crypto.encrypt(plaintext, passphrase)
        assert.is_nil(err, "encrypt should not error: " .. tostring(err))
        assert.not_nil(ct)
        local pt, err2 = crypto.decrypt(ct, passphrase)
        assert.is_nil(err2, "decrypt should not error: " .. tostring(err2))
        assert.equal(plaintext, pt)
    end)

    it("ciphertext has three colon-separated parts (iv:ct:hmac)", function()
        local ct = crypto.encrypt("data", "pass")
        local parts = {}
        for p in ct:gmatch("[^:]+") do parts[#parts+1] = p end
        assert.equal(3, #parts,
            "new format must be iv:ct:hmac (got " .. #parts .. " parts)")
    end)

    it("each part is non-empty base64", function()
        local ct = crypto.encrypt("data", "pass")
        for part in ct:gmatch("[^:]+") do
            assert(#part > 0, "each ciphertext part must be non-empty")
            assert(part:match("^[A-Za-z0-9+/=]+$"),
                "each part must be base64, got: " .. part)
        end
    end)

    it("two encryptions of the same plaintext produce different ciphertexts (fresh IVs)", function()
        local ct1 = crypto.encrypt("same-key", "same-pass")
        local ct2 = crypto.encrypt("same-key", "same-pass")
        assert.not_equal(ct1, ct2, "each encryption must use a fresh IV")
    end)

    it("wrong passphrase causes authentication failure", function()
        local ct = crypto.encrypt("secret", "right-pass")
        local pt, err = crypto.decrypt(ct, "wrong-pass")
        assert.is_nil(pt)
        assert.not_nil(err)
        assert.equal("authentication failed", err)
    end)

    it("encrypts and decrypts binary-safe content (null bytes)", function()
        local plaintext = "prefix\0middle\0suffix"
        local ct = crypto.encrypt(plaintext, "pass")
        local pt = crypto.decrypt(ct, "pass")
        assert.equal(plaintext, pt)
    end)

    it("encrypts and decrypts an empty string", function()
        local ct = crypto.encrypt("", "pass")
        local pt, err = crypto.decrypt(ct, "pass")
        assert.is_nil(err)
        assert.not_nil(pt)
        -- AES-CBC with PKCS7 padding may pad empty string to one block
        -- The decrypted result should be the empty string after unpadding.
        assert.equal("", pt)
    end)

    it("encrypts and decrypts a long string (multi-block)", function()
        local plaintext = string.rep("ABCDEFGHIJKLMNOP", 100)  -- 1600 bytes
        local ct = crypto.encrypt(plaintext, "passphrase")
        local pt = crypto.decrypt(ct, "passphrase")
        assert.equal(plaintext, pt)
    end)

end)

-- ============================================================================
-- 4. Tampered ciphertext — authentication must catch it
-- ============================================================================

describe("crypto.decrypt: tampered ciphertext", function()

    it("flipping a byte in the ciphertext body triggers authentication failure", function()
        local ct = crypto.encrypt("original plaintext", "passphrase")
        local parts = {}
        for p in ct:gmatch("[^:]+") do parts[#parts+1] = p end
        -- Flip the last character of the base64 ciphertext part
        local orig = parts[2]
        local flipped = orig:sub(1, -2) .. (orig:sub(-1) == "A" and "B" or "A")
        local tampered = parts[1] .. ":" .. flipped .. ":" .. parts[3]
        local pt, err = crypto.decrypt(tampered, "passphrase")
        assert.is_nil(pt)
        assert.equal("authentication failed", err)
    end)

    it("flipping a byte in the IV triggers authentication failure", function()
        local ct = crypto.encrypt("original plaintext", "passphrase")
        local parts = {}
        for p in ct:gmatch("[^:]+") do parts[#parts+1] = p end
        local orig = parts[1]
        -- Flip a data character near the start (pos 3 is always a base64 data char,
        -- never padding — avoids the edge case where the last char is '=' and
        -- ngx.decode_base64 ignores its mutation).
        local mid = 3
        local c   = orig:sub(mid, mid)
        local alt = (c == "A") and "B" or "A"
        local flipped = orig:sub(1, mid-1) .. alt .. orig:sub(mid+1)
        local tampered = flipped .. ":" .. parts[2] .. ":" .. parts[3]
        local pt, err = crypto.decrypt(tampered, "passphrase")
        assert.is_nil(pt)
        assert.equal("authentication failed", err)
    end)

    it("replacing the HMAC part triggers authentication failure", function()
        local ct = crypto.encrypt("original plaintext", "passphrase")
        local parts = {}
        for p in ct:gmatch("[^:]+") do parts[#parts+1] = p end
        -- Replace HMAC with 32 zero-bytes (base64-encoded)
        local fake_hmac = ngx.encode_base64(string.rep("\0", 32))
        local tampered  = parts[1] .. ":" .. parts[2] .. ":" .. fake_hmac
        local pt, err   = crypto.decrypt(tampered, "passphrase")
        assert.is_nil(pt)
        assert.equal("authentication failed", err)
    end)

    it("authentication check is order-dependent: IV ∥ CT (not CT ∥ IV)", function()
        -- Swapping IV and CT must produce a different HMAC tag → auth failure
        local ct = crypto.encrypt("data", "pass")
        local parts = {}
        for p in ct:gmatch("[^:]+") do parts[#parts+1] = p end
        -- Swap iv and ct parts (keep original hmac)
        local swapped = parts[2] .. ":" .. parts[1] .. ":" .. parts[3]
        local pt, err = crypto.decrypt(swapped, "pass")
        assert.is_nil(pt)
        assert.not_nil(err)
    end)

end)

-- ============================================================================
-- 5. Legacy 2-part format backward compatibility
-- ============================================================================

describe("crypto.decrypt: legacy 2-part format", function()

    -- Construct a legacy ciphertext by hand (iv:ct, no HMAC) using the same
    -- key derivation as crypto.lua so the AES decryption itself succeeds.
    local function make_legacy_ct(plaintext, passphrase)
        local sha256_lib = require("resty.sha256")
        local aes_lib    = require("resty.aes")
        local b64        = ngx.encode_base64

        local function derive_key(pp)
            local h = sha256_lib:new(); h:update(pp); return h:final()
        end

        local key = derive_key(passphrase)
        local iv  = crypto.random_bytes(16)
        local aes = aes_lib:new(key, nil, aes_lib.cipher(256, "cbc"), {iv = iv})
        local ct  = aes:encrypt(plaintext)
        return b64(iv) .. ":" .. b64(ct)
    end

    it("decrypts a valid legacy 2-part ciphertext and emits a WARN log", function()
        local plaintext  = "legacy-key-value"
        local passphrase = "old-passphrase"
        local legacy_ct  = make_legacy_ct(plaintext, passphrase)
        -- Confirm it really has 2 parts
        local count = 0
        for _ in legacy_ct:gmatch("[^:]+") do count = count + 1 end
        assert.equal(2, count, "test helper must produce a 2-part ciphertext")

        _warnings = {}
        local pt, err = crypto.decrypt(legacy_ct, passphrase)
        assert.is_nil(err, "legacy format should decrypt without error: " .. tostring(err))
        assert.equal(plaintext, pt)
        -- Must log a WARN about the legacy format
        local found_warn = false
        for _, w in ipairs(_warnings) do
            if w:find("legacy") or w:find("unauthenticated") then found_warn = true end
        end
        assert.is_true(found_warn, "should log a warning for legacy unauthenticated ciphertext")
    end)

    it("rejects a 1-part string as invalid format", function()
        local pt, err = crypto.decrypt("onlyonepart", "pass")
        assert.is_nil(pt)
        assert.equal("invalid ciphertext format", err)
    end)

    it("rejects a 4-part string as invalid format", function()
        local pt, err = crypto.decrypt("a:b:c:d", "pass")
        assert.is_nil(pt)
        assert.equal("invalid ciphertext format", err)
    end)

    it("rejects a ciphertext with invalid base64 in IV slot", function()
        local pt, err = crypto.decrypt("!!!:validbase64==:validbase64==", "pass")
        assert.is_nil(pt)
        assert.not_nil(err)
    end)

end)

-- ============================================================================
-- 6. HMAC key separation — enc key ≠ auth key
-- ============================================================================

describe("crypto: HMAC uses a separate derived key", function()

    it("ciphertexts encrypted with different passphrases are not cross-authenticated", function()
        local ct = crypto.encrypt("data", "passphrase-A")
        local pt, err = crypto.decrypt(ct, "passphrase-B")
        assert.is_nil(pt)
        assert.equal("authentication failed", err)
    end)

    it("encrypt+decrypt with passphrase containing special characters", function()
        local pass = "p@$$w0rd!#%^&*()"
        local ct = crypto.encrypt("value", pass)
        local pt = crypto.decrypt(ct, pass)
        assert.equal("value", pt)
    end)

    it("encrypt+decrypt with a 64-byte passphrase (HMAC block-size boundary)", function()
        local pass = string.rep("k", 64)
        local ct = crypto.encrypt("block-boundary-test", pass)
        local pt = crypto.decrypt(ct, pass)
        assert.equal("block-boundary-test", pt)
    end)

    it("encrypt+decrypt with a 65-byte passphrase (exceeds HMAC block size)", function()
        local pass = string.rep("k", 65)
        local ct = crypto.encrypt("over-block-test", pass)
        local pt = crypto.decrypt(ct, pass)
        assert.equal("over-block-test", pt)
    end)

end)
