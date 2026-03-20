-- utils/crypto.lua — hashing and symmetric encryption
-- Uses lua-resty-string (resty.sha256, resty.string, resty.aes) which ships
-- with OpenResty. AES-256-CBC with PKCS7 padding for BYOK key storage.
-- NOTE: production should use AES-256-GCM (authenticated encryption) via
--       luaossl or a KMS — CBC here is fine for dev/test.

local sha256_lib = require("resty.sha256")
local str_lib    = require("resty.string")
local aes_lib    = require("resty.aes")
local random_lib = require("resty.random")

local b64_enc = ngx.encode_base64
local b64_dec = ngx.decode_base64

local M = {}

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

-- Encrypt plaintext with AES-256-CBC.
-- Returns base64(iv) .. ":" .. base64(ciphertext), or nil, err.
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

    return b64_enc(iv) .. ":" .. b64_enc(ct)
end

-- Decrypt a value produced by M.encrypt.
-- Returns plaintext or nil, err.
function M.decrypt(ciphertext_b64, passphrase)
    local iv_b64, ct_b64 = ciphertext_b64:match("^([^:]+):(.+)$")
    if not iv_b64 then
        return nil, "invalid ciphertext format"
    end

    local iv = b64_dec(iv_b64)
    local ct = b64_dec(ct_b64)

    if not iv or not ct then
        return nil, "base64 decode failed"
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
