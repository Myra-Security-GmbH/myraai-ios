-- utils/crypto.lua — hashing and symmetric encryption
-- Uses lua-resty-string (resty.sha256, resty.string, resty.aes) which ships
-- with OpenResty. AES-256-CBC with PKCS7 padding + HMAC-SHA256 for BYOK key storage.
-- Ciphertext format: base64(iv) ":" base64(ct) ":" base64(hmac)
-- Legacy two-part format (no HMAC) is still decryptable but logged as a warning.

local sha256_lib = require("resty.sha256")
local str_lib    = require("resty.string")
local aes_lib    = require("resty.aes")
local random_lib = require("resty.random")
local bit        = require("bit")

local b64_enc = ngx.encode_base64
local b64_dec = ngx.decode_base64

local M = {}

-- ── HMAC-SHA256 (RFC 2104) ────────────────────────────────────────────────────

local HMAC_BLOCK_SIZE = 64

local function hmac_sha256_raw(key, message)
    if #key > HMAC_BLOCK_SIZE then
        local kh = sha256_lib:new(); kh:update(key); key = kh:final()
    end
    local ipad, opad = {}, {}
    for i = 1, HMAC_BLOCK_SIZE do
        local kb = i <= #key and key:byte(i) or 0
        ipad[i] = string.char(bit.bxor(kb, 0x36))
        opad[i] = string.char(bit.bxor(kb, 0x5c))
    end
    local inner = sha256_lib:new()
    inner:update(table.concat(ipad))
    inner:update(message)
    local inner_hash = inner:final()
    local outer = sha256_lib:new()
    outer:update(table.concat(opad))
    outer:update(inner_hash)
    return outer:final()
end

-- Derive a separate HMAC key from the passphrase so enc key ≠ auth key.
local function derive_hmac_key(passphrase)
    local h = sha256_lib:new()
    h:update("aig-hmac-v1:")
    h:update(passphrase)
    return h:final()
end

-- Constant-time byte comparison (prevents timing oracle on HMAC).
local function ct_eq(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = diff + bit.bxor(a:byte(i), b:byte(i)) end
    return diff == 0
end

-- SHA-256 hex digest of a string.
function M.sha256_hex(s)
    local h = sha256_lib:new()
    h:update(s)
    return str_lib.to_hex(h:final())
end

-- Generate n cryptographically-random bytes, returned as a raw string.
function M.random_bytes(n)
    return random_lib.bytes(n, true)
end

-- Generate a random hex string of length 2*n.
function M.random_hex(n)
    return str_lib.to_hex(M.random_bytes(n))
end

-- Derive a 32-byte AES key from a passphrase using SHA-256.
local function derive_key(passphrase)
    local h = sha256_lib:new()
    h:update(passphrase)
    return h:final()  -- raw 32 bytes
end

-- Encrypt plaintext with AES-256-CBC + HMAC-SHA256.
-- Returns base64(iv) ":" base64(ct) ":" base64(hmac), or nil, err.
function M.encrypt(plaintext, passphrase)
    local key = derive_key(passphrase)
    local iv  = M.random_bytes(16)

    local aes, err = aes_lib:new(key, nil, aes_lib.cipher(256, "cbc"),
                                 {iv = iv})
    if not aes then
        return nil, "aes init: " .. tostring(err)
    end

    local ct = aes:encrypt(plaintext)
    if not ct then
        return nil, "aes encrypt failed"
    end

    local mac = hmac_sha256_raw(derive_hmac_key(passphrase), iv .. ct)
    return b64_enc(iv) .. ":" .. b64_enc(ct) .. ":" .. b64_enc(mac)
end

-- Decrypt a value produced by M.encrypt.
-- Returns plaintext or nil, err.
function M.decrypt(ciphertext_b64, passphrase)
    local parts = {}
    for p in ciphertext_b64:gmatch("[^:]+") do parts[#parts + 1] = p end

    if #parts ~= 3 and #parts ~= 2 then
        return nil, "invalid ciphertext format"
    end

    local iv = b64_dec(parts[1])
    local ct = b64_dec(parts[2])
    if not iv or not ct then
        return nil, "base64 decode failed"
    end

    if #parts == 3 then
        -- Authenticated format: verify HMAC before decrypting.
        local mac = b64_dec(parts[3])
        if not mac then return nil, "base64 decode failed (hmac)" end
        local expected = hmac_sha256_raw(derive_hmac_key(passphrase), iv .. ct)
        if not ct_eq(mac, expected) then
            return nil, "authentication failed"
        end
    else
        -- Legacy unauthenticated format — still decrypt but warn.
        ngx.log(ngx.WARN, "crypto: decrypting legacy unauthenticated ciphertext")
    end

    local key = derive_key(passphrase)
    local aes, err = aes_lib:new(key, nil, aes_lib.cipher(256, "cbc"),
                                 {iv = iv})
    if not aes then
        return nil, "aes init: " .. tostring(err)
    end

    local pt = aes:decrypt(ct)
    if not pt then
        return nil, "aes decrypt failed"
    end

    return pt
end

return M
