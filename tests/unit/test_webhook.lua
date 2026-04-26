-- tests/unit/test_webhook.lua
-- Tests for utils/webhook.lua fire-and-forget webhook delivery
-- Run with: resty tests/runner.lua tests/unit/test_webhook.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls    = {}
local _timer_calls  = {}

_G.ngx = {
    log  = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    time = function() return 1700000000 end,
    -- Synchronously execute the timer callback so we can inspect delivery
    timer = {
        at = function(_, fn, ...)
            local args = {...}
            _timer_calls[#_timer_calls+1] = { fn = fn, args = args }
            -- Execute immediately in tests
            fn(nil, table.unpack(args))
            return true, nil
        end,
    },
    WARN = 1, INFO = 2, ERR = 0,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Save real resty.sha256 before mock setup.  The runner.lua protects
-- package.loaded["resty.sha256"] = nil, so this require always returns the
-- real C module regardless of what earlier tests set as a mock.
local _real_sha256 = require("resty.sha256")

-- ─── module stubs ──────────────────────────────────────────────────────────
for _, n in ipairs({ "utils.webhook", "resty.http", "resty.string" }) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end
-- The runner.lua protection intercepts nil-writes to resty.sha256, so the
-- real module stays in package.loaded.  Mock preloads below are never invoked
-- (package.loaded is always non-nil), which is fine — tests only check the
-- "sha256=" prefix, not the exact HMAC value.
package.loaded["resty.sha256"] = nil  -- no-op due to runner protection

-- resty.sha256 stub
package.preload["resty.sha256"] = function()
    return {
        new = function()
            local data = ""
            return {
                update = function(self, s) data = data .. s end,
                final  = function(self) return data:sub(1, 32) end,
            }
        end,
    }
end

-- resty.string stub
package.preload["resty.string"] = function()
    return { to_hex = function(s) return "deadbeef" end }
end

-- resty.http stub — records requests
local _http_requests = {}
local _http_error    = nil   -- set to a string to simulate delivery failure

package.preload["resty.http"] = function()
    return {
        new = function()
            return {
                set_timeout   = function() end,
                request_uri   = function(self, url, opts)
                    _http_requests[#_http_requests+1] = {
                        url     = url,
                        method  = opts.method,
                        body    = opts.body,
                        headers = opts.headers,
                    }
                    if _http_error then return nil, _http_error end
                    return { status = 200 }, nil
                end,
            }
        end,
    }
end

local wh = require("utils.webhook")

-- ─── helpers ───────────────────────────────────────────────────────────────
local function reset()
    _log_calls    = {}
    _timer_calls  = {}
    _http_requests = {}
    _http_error   = nil
end

-- ─── test suite ────────────────────────────────────────────────────────────
describe("webhook.fire: no-op cases", function()
    before_each(reset)

    it("does nothing when webhook_cfg is nil", function()
        wh.fire(nil, "blocked", {}, {})
        assert.equal(0, #_http_requests)
    end)

    it("does nothing when webhook_cfg is not a table", function()
        wh.fire("not-a-table", "blocked", {}, {})
        assert.equal(0, #_http_requests)
    end)

    it("does nothing when url is empty", function()
        wh.fire({ url = "" }, "blocked", {}, {})
        assert.equal(0, #_http_requests)
    end)

    it("does nothing when url is absent", function()
        wh.fire({ events = {"blocked"} }, "blocked", {}, {})
        assert.equal(0, #_http_requests)
    end)

    it("skips event not in subscribed list", function()
        wh.fire({ url = "http://h.test/", events = {"circuit_open"} }, "blocked", {}, {})
        assert.equal(0, #_http_requests)
    end)
end)

describe("webhook.fire: delivery", function()
    before_each(reset)

    it("fires POST to configured url", function()
        wh.fire({ url = "http://h.test/hook" }, "blocked", { model = "gpt-4o" }, { gateway_id = "gw1" })
        assert.equal(1, #_http_requests)
        assert.equal("http://h.test/hook", _http_requests[1].url)
        assert.equal("POST", _http_requests[1].method)
    end)

    it("payload contains event, gateway_id, tenant_id, ts", function()
        local cjson = require("cjson")
        wh.fire({ url = "http://h.test/" }, "budget_exceeded",
                { scope = "tenant" }, { gateway_id = "gw1", tenant_id = "t1" })
        local payload = cjson.decode(_http_requests[1].body)
        assert.equal("budget_exceeded", payload.event)
        assert.equal("gw1", payload.gateway_id)
        assert.equal("t1", payload.tenant_id)
        assert.truthy(payload.ts)
        assert.equal("tenant", payload.data.scope)
    end)

    it("fires when event is in subscribed list", function()
        wh.fire({ url = "http://h.test/", events = {"blocked", "circuit_open"} },
                "circuit_open", {}, {})
        assert.equal(1, #_http_requests)
    end)

    it("fires when events list is absent (subscribe all)", function()
        wh.fire({ url = "http://h.test/" }, "any_event", {}, {})
        assert.equal(1, #_http_requests)
    end)

    it("adds X-AIG-Signature header when secret is provided", function()
        wh.fire({ url = "http://h.test/", secret = "mysecret" }, "blocked", {}, {})
        local sig = _http_requests[1].headers["X-AIG-Signature"]
        assert.truthy(sig)
        assert.match("^sha256=", sig)
    end)

    it("omits X-AIG-Signature when no secret", function()
        wh.fire({ url = "http://h.test/" }, "blocked", {}, {})
        assert.is_nil(_http_requests[1].headers["X-AIG-Signature"])
    end)

    it("logs warning on delivery error", function()
        _http_error = "connection refused"
        wh.fire({ url = "http://down.test/" }, "blocked", {}, {})
        assert.equal(1, #_log_calls)
        assert.match("connection refused", _log_calls[1])
    end)
end)

-- ── Finding 13: HMAC correctness — uses real resty.sha256 ────────────────────
-- Clear the sha256/string stubs so we can verify actual HMAC-SHA256 output.

do
    -- Reset to real resty modules for the HMAC correctness tests.
    -- resty.sha256 is restored from the saved reference (not re-required, which
    -- would trigger a C FFI redefinition error).
    for _, n in ipairs({"utils.webhook","resty.string","resty.hmac"}) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
    package.loaded["resty.sha256"]  = _real_sha256
    package.preload["resty.sha256"] = nil
    -- resty.http stub re-declared so webhook delivery still works without network
    package.preload["resty.http"] = function()
        return {
            new = function()
                return {
                    set_timeout   = function() end,
                    request_uri   = function(_, _, opts)
                        _http_requests[#_http_requests+1] = {
                            headers = opts.headers,
                            body    = opts.body,
                        }
                        return { status = 200 }, nil
                    end,
                }
            end,
        }
    end
end

local wh_real = require("utils.webhook")  -- loaded with real sha256

-- Reference HMAC-SHA256 implementation for test verification.
local function ref_hmac(key, msg)
    local sha256 = require("resty.sha256")
    local rstr   = require("resty.string")
    local bit_   = require("bit")
    local BLOCK  = 64
    if #key > BLOCK then
        local kh = sha256:new(); kh:update(key); key = kh:final()
    end
    local ipad, opad = {}, {}
    for i = 1, BLOCK do
        local kb = i <= #key and key:byte(i) or 0
        ipad[i] = string.char(bit_.bxor(kb, 0x36))
        opad[i] = string.char(bit_.bxor(kb, 0x5c))
    end
    local inner = sha256:new()
    inner:update(table.concat(ipad))
    inner:update(msg)
    local ihash = inner:final()
    local outer = sha256:new()
    outer:update(table.concat(opad))
    outer:update(ihash)
    return rstr.to_hex(outer:final())
end

-- Compute the old (insecure) H(secret || body) for comparison.
local function ref_keyed_hash(secret, body)
    local sha256 = require("resty.sha256")
    local rstr   = require("resty.string")
    local h = sha256:new()
    h:update(secret)
    h:update(body)
    return rstr.to_hex(h:final())
end

describe("webhook.sign: proper HMAC-SHA256 (Finding 13)", function()

    local function fire_and_capture(secret, event, data)
        _http_requests = {}
        wh_real.fire({ url = "http://hook.test/", secret = secret },
                     event, data, { gateway_id = "gw1", tenant_id = "tn1" })
        if #_http_requests == 0 then return nil, nil end
        local req = _http_requests[1]
        local sig = req.headers and req.headers["X-AIG-Signature"]
        -- sig is "sha256=<hex>"
        local hex = sig and sig:match("^sha256=(.+)$")
        return hex, req.body
    end

    it("signature is present and in sha256=<hex> format", function()
        _http_requests = {}
        wh_real.fire({ url = "http://hook.test/", secret = "mysecret" },
                     "blocked", {}, {})
        assert.equal(1, #_http_requests)
        local sig = _http_requests[1].headers["X-AIG-Signature"]
        assert.not_nil(sig, "X-AIG-Signature header must be present")
        assert(sig:match("^sha256=[0-9a-f]+$"),
            "signature must be sha256=<hex>, got: " .. tostring(sig))
        -- HMAC-SHA256 hex is 64 chars
        local hex = sig:match("^sha256=(.+)$")
        assert.equal(64, #hex, "HMAC-SHA256 hex must be 64 chars")
    end)

    it("signature matches RFC 2104 HMAC-SHA256, not H(secret||body)", function()
        local secret = "test-signing-secret"
        local hex, body = fire_and_capture(secret, "blocked", { reason = "policy" })
        assert.not_nil(hex, "signature hex must not be nil")
        assert.not_nil(body, "payload body must not be nil")

        local expected_hmac  = ref_hmac(secret, body)
        local old_keyed_hash = ref_keyed_hash(secret, body)

        assert.equal(expected_hmac, hex,
            "signature must be proper HMAC-SHA256")
        -- Verify the fix: old H(secret||body) would produce a DIFFERENT value
        assert.not_equal(old_keyed_hash, hex,
            "signature must NOT be the old H(secret||body) keyed hash")
    end)

    it("different body produces different signature", function()
        local hex1, body1 = fire_and_capture("secret", "blocked", { x = 1 })
        local hex2, body2 = fire_and_capture("secret", "blocked", { x = 2 })
        assert.not_equal(body1, body2, "payloads should differ")
        assert.not_equal(hex1, hex2, "different body must produce different HMAC")
    end)

    it("different secret produces different signature for same payload", function()
        -- Fire twice with the same event/data but different secrets.
        -- Since ngx.time() is fixed the payloads will be identical.
        local hex1, _ = fire_and_capture("secret-A", "circuit_open", {})
        local hex2, _ = fire_and_capture("secret-B", "circuit_open", {})
        assert.not_equal(hex1, hex2, "different secret must produce different HMAC")
    end)

    it("no secret → no X-AIG-Signature header", function()
        _http_requests = {}
        wh_real.fire({ url = "http://hook.test/" }, "blocked", {}, {})
        assert.equal(1, #_http_requests)
        local sig = _http_requests[1].headers["X-AIG-Signature"]
        assert.is_nil(sig, "no secret must produce no signature header")
    end)

end)
