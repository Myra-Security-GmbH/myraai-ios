-- tests/unit/test_sigv4.lua
-- Unit tests for utils/sigv4.lua
--
-- The canonical_uri / canonical_query / canonical_headers functions are pure
-- string manipulation — tested directly against known expected values.
--
-- sign() requires HMAC-SHA256 and SHA-256.  We mock resty.sha256, resty.hmac,
-- and resty.string with minimal implementations that:
--   • Return deterministic fixed bytes so Authorization header structure is
--     verifiable.
--   • Allow the format/logic tests to pass without needing OpenResty.
--
-- Run with: busted tests/unit/test_sigv4.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- ── crypto mocks ────────────────────────────────────────────────────────────
-- Clear first so the preload entries we set below are not wiped by clear().

local FAKE_HASH_BYTES = string.rep("\xab", 32)   -- 32 "bytes"
local FAKE_HASH_HEX   = string.rep("ab", 32)      -- 64 hex chars

clear({"utils.sigv4","resty.sha256","resty.string","resty.hmac"})

-- Set mocks AFTER clear so they are not removed.
package.preload["resty.sha256"] = function()
    return {
        new = function()
            return {
                update = function() end,
                final  = function() return FAKE_HASH_BYTES end,
            }
        end,
    }
end

package.preload["resty.string"] = function()
    return {
        to_hex = function(s)
            return s:gsub(".", function(c)
                return string.format("%02x", string.byte(c))
            end)
        end,
    }
end

package.preload["resty.hmac"] = function()
    return {
        ALGOS = { SHA256 = 1 },
        new   = function(self, _key, _algo)
            return {
                update = function() end,
                final  = function() return FAKE_HASH_BYTES end,
            }
        end,
    }
end
local sigv4 = require("utils.sigv4")

-- ── canonical_uri ───────────────────────────────────────────────────────────

describe("sigv4.canonical_uri", function()
    it("returns '/' for empty input", function()
        assert.equal("/", sigv4.canonical_uri(""))
        assert.equal("/", sigv4.canonical_uri(nil))
    end)

    it("returns '/' unchanged", function()
        assert.equal("/", sigv4.canonical_uri("/"))
    end)

    it("preserves simple path", function()
        assert.equal("/model/foo/invoke", sigv4.canonical_uri("/model/foo/invoke"))
    end)

    it("encodes spaces in path segments", function()
        local result = sigv4.canonical_uri("/path/has space/here")
        assert.equal("/path/has%20space/here", result)
    end)

    it("encodes special characters in segments", function()
        local result = sigv4.canonical_uri("/path/a+b/c=d")
        assert(result:find("%%2B") or result:find("%%3D"),
            "'+' and '=' should be percent-encoded in path segments")
    end)

    it("preserves unreserved characters A-Z a-z 0-9 - _ . ~", function()
        local result = sigv4.canonical_uri("/aZ09-_.~/end")
        assert.equal("/aZ09-_.~/end", result)
    end)
end)

-- ── canonical_query ─────────────────────────────────────────────────────────

describe("sigv4.canonical_query", function()
    it("returns '' for empty input", function()
        assert.equal("", sigv4.canonical_query(""))
        assert.equal("", sigv4.canonical_query(nil))
    end)

    it("returns single param unchanged", function()
        assert.equal("Action=DescribeInstances", sigv4.canonical_query("Action=DescribeInstances"))
    end)

    it("sorts params alphabetically by key", function()
        local result = sigv4.canonical_query("Zoo=val&Alpha=val&Middle=val")
        assert.equal("Alpha=val&Middle=val&Zoo=val", result)
    end)

    it("sorts by value when keys are equal", function()
        local result = sigv4.canonical_query("x=b&x=a")
        assert.equal("x=a&x=b", result)
    end)

    it("URL-encodes spaces in values as %20", function()
        local result = sigv4.canonical_query("key=hello world")
        assert.equal("key=hello%20world", result)
    end)

    it("URL-encodes + in values as %2B", function()
        local result = sigv4.canonical_query("key=a+b")
        assert.equal("key=a%2Bb", result)
    end)

    it("handles alt=sse correctly (Gemini Bedrock use case)", function()
        local result = sigv4.canonical_query("alt=sse")
        assert.equal("alt=sse", result)
    end)
end)

-- ── canonical_headers ───────────────────────────────────────────────────────

describe("sigv4.canonical_headers", function()
    it("produces name:value\\n per header with terminating newline", function()
        local headers = { ["host"] = "example.amazonaws.com", ["x-amz-date"] = "20150830T123600Z" }
        local signed   = { "host", "x-amz-date" }
        local result   = sigv4.canonical_headers(headers, signed)
        assert.equal("host:example.amazonaws.com\nx-amz-date:20150830T123600Z\n", result)
    end)

    it("trims leading and trailing whitespace from values", function()
        local headers = { ["content-type"] = "  application/json  " }
        local signed   = { "content-type" }
        local result   = sigv4.canonical_headers(headers, signed)
        assert.equal("content-type:application/json\n", result)
    end)

    it("collapses consecutive internal whitespace to single space", function()
        local headers = { ["x-custom"] = "foo   bar" }
        local signed   = { "x-custom" }
        local result   = sigv4.canonical_headers(headers, signed)
        assert.equal("x-custom:foo bar\n", result)
    end)

    it("lowercases header names", function()
        local headers = { ["Host"] = "example.com" }
        local signed   = { "host" }    -- signed list is already lowercase
        local result   = sigv4.canonical_headers(headers, signed)
        assert.equal("host:example.com\n", result)
    end)

    it("produces empty string for empty signed list", function()
        local result = sigv4.canonical_headers({}, {})
        assert.equal("", result)
    end)
end)

-- ── canonical_request ───────────────────────────────────────────────────────

describe("sigv4.canonical_request", function()
    it("produces newline-separated six-part string", function()
        local headers    = { ["host"] = "svc.us-east-1.amazonaws.com",
                             ["x-amz-date"] = "20240101T120000Z" }
        local signed     = { "host", "x-amz-date" }
        local result     = sigv4.canonical_request(
            "POST", "/model/foo/invoke", "", headers, signed, "{}")

        local parts = {}
        for p in (result .. "\n"):gmatch("([^\n]*)\n") do
            parts[#parts + 1] = p
        end
        -- Parts: method, uri, query, canonical_headers (4 lines), signed_headers, payload_hash
        assert.equal("POST",                       parts[1])
        assert.equal("/model/foo/invoke",           parts[2])
        assert.equal("",                            parts[3])  -- empty query
        assert.equal("host:svc.us-east-1.amazonaws.com", parts[4])
        assert.equal("x-amz-date:20240101T120000Z", parts[5])
        assert.equal("",                            parts[6])  -- canonical_headers trailing blank line
        assert.equal("host;x-amz-date",             parts[7])
        -- parts[8] = payload hash — 64-char lowercase hex regardless of sha256 implementation
        assert.is_true(#parts[8] == 64 and parts[8]:match("^[0-9a-f]+$") ~= nil,
            "payload hash must be a 64-char hex string, got: " .. tostring(parts[8]))
    end)
end)

-- ── sign ────────────────────────────────────────────────────────────────────

describe("sigv4.sign", function()
    local function do_sign()
        return sigv4.sign(
            "POST",
            "/model/anthropic.claude-3-5-sonnet-20241022-v2:0/invoke",
            "",
            {
                ["content-type"] = "application/json",
                ["host"]         = "bedrock-runtime.us-east-1.amazonaws.com",
                ["x-amz-date"]   = "20240101T120000Z",
            },
            { "content-type", "host", "x-amz-date" },
            [[{"messages":[{"role":"user","content":"hi"}],"max_tokens":256}]],
            "AKIAIOSFODNN7EXAMPLE",
            "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            "20240101T120000Z",
            "us-east-1",
            "bedrock"
        )
    end

    it("returns a string", function()
        assert.is_string(do_sign())
    end)

    it("starts with AWS4-HMAC-SHA256", function()
        assert(do_sign():find("^AWS4%-HMAC%-SHA256 "))
    end)

    it("contains Credential= with access key", function()
        assert(do_sign():find("Credential=AKIAIOSFODNN7EXAMPLE/"))
    end)

    it("Credential includes date, region and service", function()
        local auth = do_sign()
        assert(auth:find("20240101/us%-east%-1/bedrock/aws4_request"))
    end)

    it("contains SignedHeaders=", function()
        assert(do_sign():find("SignedHeaders=content%-type;host;x%-amz%-date"))
    end)

    it("contains Signature= with 64-char hex string", function()
        local sig = do_sign():match("Signature=(%x+)")
        assert.not_nil(sig)
        assert.equal(64, #sig)
    end)

    it("includes session token header in SignedHeaders when provided", function()
        local auth = sigv4.sign(
            "POST", "/model/foo/invoke", "",
            {
                ["content-type"]         = "application/json",
                ["host"]                 = "bedrock-runtime.us-east-1.amazonaws.com",
                ["x-amz-date"]           = "20240101T120000Z",
                ["x-amz-security-token"] = "AQoDYXdzEFakeToken==",
            },
            { "content-type", "host", "x-amz-date", "x-amz-security-token" },
            "{}",
            "AKID", "SECRET", "20240101T120000Z", "us-east-1", "bedrock"
        )
        assert(auth:find("x%-amz%-security%-token"),
            "x-amz-security-token must appear in SignedHeaders when a session token is used")
    end)
end)
