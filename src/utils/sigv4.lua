-- utils/sigv4.lua — AWS Signature Version 4 request signing
--
-- Reference: https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
--
-- Public API:
--   M.canonical_uri(path)
--   M.canonical_query(query_str)
--   M.canonical_headers(headers, signed_headers_list)
--   M.canonical_request(method, uri, query, headers, signed_headers, payload)
--   M.sign(method, uri, query, headers, signed_headers, payload,
--          access_key, secret_key, datetime, region, service)
--     → Authorization header value string
--
-- BYOK key format for Bedrock: "ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]"

local sha256_lib = require("resty.sha256")
local str_lib    = require("resty.string")
local hmac_lib   = require("resty.hmac")

local M = {}

-- SHA-256 hex digest of a string.
local function sha256_hex(s)
    local h = sha256_lib:new()
    h:update(s)
    return str_lib.to_hex(h:final())
end

-- HMAC-SHA256: key (raw bytes string) × data (string) → raw bytes string.
local function hmac_sha256(key, data)
    local h = hmac_lib:new(key, hmac_lib.ALGOS.SHA256)
    h:update(data)
    return h:final()
end

-- HMAC-SHA256 returning lowercase hex.
local function hmac_sha256_hex(key, data)
    return str_lib.to_hex(hmac_sha256(key, data))
end

-- Percent-encode a byte as %XX.
-- SigV4 unreserved characters: A-Z a-z 0-9 - _ . ~
-- encode_slash=true also encodes "/" (used for path segments).
local function pct_encode(c)
    return string.format("%%%02X", string.byte(c))
end

local function uri_encode(s, encode_slash)
    local safe = encode_slash
        and "^[A-Za-z0-9%-_.~]$"
        or  "^[A-Za-z0-9%-_.~/]$"
    return (s:gsub(".", function(c)
        if c:match(safe) then return c end
        return pct_encode(c)
    end))
end

-- Build the canonical URI.
-- SigV4 requires percent-encoding every character that is not an unreserved
-- character (A-Z a-z 0-9 - _ . ~) or a slash (path separator).
-- Returns "/" for empty/nil paths.
function M.canonical_uri(path)
    if not path or path == "" then return "/" end
    return (path:gsub("([^A-Za-z0-9%-_.~/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build the canonical query string.
-- Parameters are sorted by encoded key, then encoded value.
-- Returns "" for empty/nil input.
function M.canonical_query(query_str)
    if not query_str or query_str == "" then return "" end
    local params = {}
    for pair in (query_str .. "&"):gmatch("([^&]+)") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        params[#params + 1] = { uri_encode(k, true), uri_encode(v or "", true) }
    end
    table.sort(params, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    local parts = {}
    for _, p in ipairs(params) do
        parts[#parts + 1] = p[1] .. "=" .. p[2]
    end
    return table.concat(parts, "&")
end

-- Build the canonical headers block.
-- signed_headers_list: sorted array of lowercase header names to include.
-- Returns the block terminated with "\n".
function M.canonical_headers(headers, signed_headers_list)
    -- Build lowercase-keyed lookup for case-insensitive header access.
    local lc = {}
    for k, v in pairs(headers) do lc[k:lower()] = v end
    local lines = {}
    for _, name in ipairs(signed_headers_list) do
        local v = lc[name:lower()] or ""
        -- Collapse consecutive whitespace in values per SigV4 spec.
        v = v:match("^%s*(.-)%s*$"):gsub("%s+", " ")
        lines[#lines + 1] = name:lower() .. ":" .. v
    end
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

-- Build the full canonical request string.
function M.canonical_request(method, uri, query, headers, signed_headers, payload)
    local payload_hash   = sha256_hex(payload or "")
    local canonical_hdrs = M.canonical_headers(headers, signed_headers)
    local signed_str     = table.concat(signed_headers, ";")
    return table.concat({
        method:upper(),
        M.canonical_uri(uri),
        M.canonical_query(query or ""),
        canonical_hdrs,
        signed_str,
        payload_hash,
    }, "\n")
end

-- Derive the SigV4 signing key (raw bytes).
local function derive_signing_key(secret_key, date_stamp, region, service)
    local k_date    = hmac_sha256("AWS4" .. secret_key, date_stamp)
    local k_region  = hmac_sha256(k_date,    region)
    local k_service = hmac_sha256(k_region,  service)
    return hmac_sha256(k_service, "aws4_request")
end

-- Sign a request and return the Authorization header value.
--
-- Parameters:
--   method        : HTTP method uppercase ("POST")
--   uri           : path only ("/model/foo/invoke")
--   query         : query string without "?" — "" or nil for none
--   headers       : table of ALL headers that will be sent (keys as they'll appear in the request)
--   signed_headers: sorted array of lowercase header names to include in sig
--   payload       : raw request body string
--   access_key    : AWS Access Key ID
--   secret_key    : AWS Secret Access Key
--   datetime      : "YYYYMMDDTHHmmssZ" (e.g., "20240101T120000Z")
--   region        : AWS region ("us-east-1")
--   service       : AWS service ("bedrock")
--
-- Returns the full Authorization header value.
function M.sign(method, uri, query, headers, signed_headers,
                payload, access_key, secret_key, datetime, region, service)
    local date_stamp  = datetime:sub(1, 8)
    local scope       = date_stamp .. "/" .. region .. "/" .. service .. "/aws4_request"
    local canon_req   = M.canonical_request(method, uri, query, headers, signed_headers, payload)
    local str_to_sign = "AWS4-HMAC-SHA256\n"
                      .. datetime .. "\n"
                      .. scope .. "\n"
                      .. sha256_hex(canon_req)
    local signing_key = derive_signing_key(secret_key, date_stamp, region, service)
    local signature   = hmac_sha256_hex(signing_key, str_to_sign)
    local signed_str  = table.concat(signed_headers, ";")
    return "AWS4-HMAC-SHA256 Credential=" .. access_key .. "/" .. scope
        .. ", SignedHeaders=" .. signed_str
        .. ", Signature=" .. signature
end

return M
