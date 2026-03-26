-- utils/jwt.lua — HS256 JSON Web Token sign/verify
-- Uses resty.sha256 (bundled with OpenResty) to implement HMAC-SHA256.
-- Secret is read from cfg.auth.jwt_secret at first use.

local sha256_lib = require("resty.sha256")
local cjson      = require("cjson.safe")
local bit        = require("bit")

local M = {}

-- ---------------------------------------------------------------------------
-- HMAC-SHA256 via resty.sha256 (RFC 2104)
-- ---------------------------------------------------------------------------

local BLOCK_SIZE = 64  -- SHA-256 block size in bytes

local function hmac_sha256(key, message)
    -- If key is longer than block size, hash it first
    if #key > BLOCK_SIZE then
        local kh = sha256_lib:new()
        kh:update(key)
        key = kh:final()
    end

    local ipad, opad = {}, {}
    for i = 1, BLOCK_SIZE do
        local kb = i <= #key and key:byte(i) or 0
        ipad[i] = string.char(bit.bxor(kb, 0x36))
        opad[i] = string.char(bit.bxor(kb, 0x5c))
    end
    local ipad_key = table.concat(ipad)
    local opad_key = table.concat(opad)

    local inner = sha256_lib:new()
    inner:update(ipad_key)
    inner:update(message)
    local inner_hash = inner:final()

    local outer = sha256_lib:new()
    outer:update(opad_key)
    outer:update(inner_hash)
    return outer:final()
end

-- ---------------------------------------------------------------------------
-- Base64url helpers (RFC 4648 §5, no padding)
-- ---------------------------------------------------------------------------

local function b64url_enc(s)
    return (ngx.encode_base64(s):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function b64url_dec(s)
    local pad = (4 - #s % 4) % 4
    s = s .. string.rep("=", pad)
    s = s:gsub("-", "+"):gsub("_", "/")
    return ngx.decode_base64(s)
end

-- ---------------------------------------------------------------------------
-- Secret accessor (lazy, cached per-worker)
-- ---------------------------------------------------------------------------

local _secret
local function get_secret()
    if not _secret then
        local ok, cfg = pcall(require, "core.app_config")
        _secret = (ok and cfg.auth and cfg.auth.jwt_secret)
                  or os.getenv("AIG_JWT_SECRET")
                  or "dev-change-me"
        if _secret == "dev-change-me" then
            ngx.log(ngx.WARN, "jwt: using insecure default secret — set AIG_JWT_SECRET in production")
        end
    end
    return _secret
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Sign a payload table. Returns a JWT string.
function M.sign(payload)
    local header  = b64url_enc(cjson.encode({ alg = "HS256", typ = "JWT" }))
    local body    = b64url_enc(cjson.encode(payload))
    local input   = header .. "." .. body
    local sig     = b64url_enc(hmac_sha256(get_secret(), input))
    return input .. "." .. sig
end

-- Verify a JWT string.
-- Returns payload table on success, or nil, err_string on failure.
function M.verify(token)
    if not token then return nil, "missing token" end

    local parts = {}
    for p in token:gmatch("[^%.]+") do parts[#parts + 1] = p end
    if #parts ~= 3 then return nil, "malformed token" end

    local input    = parts[1] .. "." .. parts[2]
    local expected = b64url_enc(hmac_sha256(get_secret(), input))

    -- Constant-time comparison to prevent timing attacks
    if #expected ~= #parts[3] then return nil, "invalid signature" end
    local diff = 0
    for i = 1, #expected do
        diff = diff + bit.bxor(expected:byte(i), parts[3]:byte(i))
    end
    if diff ~= 0 then return nil, "invalid signature" end

    local payload_json = b64url_dec(parts[2])
    if not payload_json then return nil, "base64 decode failed" end

    local payload = cjson.decode(payload_json)
    if not payload then return nil, "json decode failed" end

    local now = ngx.time()
    if payload.exp and payload.exp < now then return nil, "token expired" end
    if payload.nbf and payload.nbf > now then return nil, "token not yet valid" end

    return payload
end

return M
