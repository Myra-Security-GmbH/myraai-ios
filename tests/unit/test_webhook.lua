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

-- ─── module stubs ──────────────────────────────────────────────────────────
for _, n in ipairs({ "utils.webhook", "resty.http", "resty.sha256", "resty.string" }) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

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
