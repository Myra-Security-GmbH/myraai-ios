-- tests/unit/test_siem.lua
-- Tests for observability/siem.lua async SIEM delivery
-- Run with: resty tests/runner.lua tests/unit/test_siem.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls   = {}
local _timer_calls = {}
local _udp_sends   = {}
local _tcp_sends   = {}

_G.ngx = {
    log  = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    now  = function() return 1700000000.123 end,
    time = function() return 1700000000 end,
    timer = {
        at = function(_, fn, ...)
            local args = {...}
            _timer_calls[#_timer_calls+1] = { fn = fn, args = args }
            fn(nil, (table.unpack or unpack)(args))
            return true, nil
        end,
    },
    socket = {
        udp = function()
            local msgs = {}
            local sock = {
                setpeername = function(self, h, p)
                    self._host = h; self._port = p
                    return true, nil
                end,
                send = function(self, msg)
                    _udp_sends[#_udp_sends+1] = { host = self._host, port = self._port, msg = msg }
                    return true, nil
                end,
                close = function() end,
            }
            return sock
        end,
        tcp = function()
            local sock = {
                connect = function(self, h, p)
                    self._host = h; self._port = p
                    return true, nil
                end,
                send = function(self, msg)
                    _tcp_sends[#_tcp_sends+1] = { host = self._host, port = self._port, msg = msg }
                    return true, nil
                end,
                close = function() end,
            }
            return sock
        end,
    },
    encode_base64 = function(s)
        -- naive stub: just return the input wrapped
        return "b64(" .. s .. ")"
    end,
    WARN = 1, INFO = 2, ERR = 0,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ─── module stubs ──────────────────────────────────────────────────────────
for _, n in ipairs({ "observability.siem", "resty.http", "resty.sha256", "resty.string" }) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

-- resty.http stub — records HTTP requests
local _http_requests = {}
local _http_error    = nil

package.preload["resty.http"] = function()
    return {
        new = function()
            return {
                set_timeout = function() end,
                request_uri = function(self, url, opts)
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

local siem = require("observability.siem")

-- ─── helpers ───────────────────────────────────────────────────────────────
local function reset()
    _log_calls    = {}
    _timer_calls  = {}
    _http_requests = {}
    _udp_sends    = {}
    _tcp_sends    = {}
    _http_error   = nil
end

local function blocked_fields()
    return {
        id         = "req-1",
        tenant_id  = "t1",
        gateway_id = "gw1",
        provider   = "openai",
        model      = "gpt-4o",
        status     = 403,
        blocked    = true,
        blocked_by = "guardrail",
        block_reason = "keyword match: badword",
        detectors_fired = {"keyword"},
        scrub_applied   = false,
        cost_usd        = 0.001,
    }
end

local function normal_fields()
    return {
        id         = "req-2",
        tenant_id  = "t1",
        gateway_id = "gw1",
        provider   = "openai",
        model      = "gpt-4o",
        status     = 200,
        blocked    = false,
        blocked_by = nil,
        detectors_fired = {},
        scrub_applied   = false,
        cost_usd  = 0.002,
    }
end

local function scrubbed_fields()
    local f = normal_fields()
    f.scrub_applied = true
    return f
end

-- ─── should_emit (event filter) ────────────────────────────────────────────
describe("siem.emit: event filter — default (no events configured)", function()
    before_each(reset)

    it("emits blocked request when events absent", function()
        siem.emit({ type = "vector", url = "http://v.test/" }, blocked_fields())
        assert.equal(1, #_http_requests)
    end)

    it("does NOT emit normal request when events absent", function()
        siem.emit({ type = "vector", url = "http://v.test/" }, normal_fields())
        assert.equal(0, #_http_requests)
    end)

    it("does NOT emit normal request when events = {}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {} }, normal_fields())
        assert.equal(0, #_http_requests)
    end)
end)

describe("siem.emit: event filter — explicit events list", function()
    before_each(reset)

    it("emits everything when events = {'all'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"all"} }, normal_fields())
        assert.equal(1, #_http_requests)
    end)

    it("emits blocked request when events = {'blocked'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"blocked"} }, blocked_fields())
        assert.equal(1, #_http_requests)
    end)

    it("does NOT emit normal when events = {'blocked'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"blocked"} }, normal_fields())
        assert.equal(0, #_http_requests)
    end)

    it("emits guardrail hit when events = {'guardrail'}", function()
        local f = normal_fields()
        f.detectors_fired = {"keyword", "pii"}
        siem.emit({ type = "vector", url = "http://v.test/", events = {"guardrail"} }, f)
        assert.equal(1, #_http_requests)
    end)

    it("does NOT emit when detectors_fired is empty and events = {'guardrail'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"guardrail"} }, normal_fields())
        assert.equal(0, #_http_requests)
    end)

    it("emits scrubbed request when events = {'scrubbed'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"scrubbed"} }, scrubbed_fields())
        assert.equal(1, #_http_requests)
    end)

    it("does NOT emit unscrubbed request when events = {'scrubbed'}", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"scrubbed"} }, normal_fields())
        assert.equal(0, #_http_requests)
    end)

    it("emits when any matching event is in the list", function()
        siem.emit({ type = "vector", url = "http://v.test/", events = {"scrubbed", "blocked"} }, blocked_fields())
        assert.equal(1, #_http_requests)
    end)
end)

-- ─── no-op cases ───────────────────────────────────────────────────────────
describe("siem.emit: no-op cases", function()
    before_each(reset)

    it("does nothing when siem_cfg is nil", function()
        siem.emit(nil, blocked_fields())
        assert.equal(0, #_http_requests)
        assert.equal(0, #_udp_sends)
    end)

    it("does nothing when siem_cfg is not a table", function()
        siem.emit("not-a-table", blocked_fields())
        assert.equal(0, #_http_requests)
    end)

    it("logs warning for unknown backend type", function()
        siem.emit({ type = "unknown_backend", events = {"all"} }, blocked_fields())
        assert.equal(1, #_log_calls)
        assert.match("unknown backend type", _log_calls[1])
    end)
end)

-- ─── Splunk HEC backend ─────────────────────────────────────────────────────
describe("siem.emit: splunk_hec backend", function()
    before_each(reset)

    local cfg = {
        type   = "splunk_hec",
        url    = "https://splunk.test:8088/services/collector/event",
        token  = "abc-123",
        index  = "ai-gateway",
        events = {"blocked"},
    }

    it("POSTs to configured HEC url", function()
        siem.emit(cfg, blocked_fields())
        assert.equal(1, #_http_requests)
        assert.equal(cfg.url, _http_requests[1].url)
        assert.equal("POST", _http_requests[1].method)
    end)

    it("sets Authorization: Splunk <token> header", function()
        siem.emit(cfg, blocked_fields())
        local auth = _http_requests[1].headers["Authorization"]
        assert.equal("Splunk abc-123", auth)
    end)

    it("payload wraps event fields under 'event' key", function()
        siem.emit(cfg, blocked_fields())
        local ok, payload = pcall(require("cjson").decode, _http_requests[1].body)
        assert.truthy(ok)
        assert.truthy(payload.event)
        assert.equal("t1", payload.event.tenant_id)
    end)

    it("payload includes 'time' and 'sourcetype' fields", function()
        siem.emit(cfg, blocked_fields())
        local payload = require("cjson").decode(_http_requests[1].body)
        assert.truthy(payload.time)
        assert.equal("_json", payload.sourcetype)
    end)

    it("payload includes configured index", function()
        siem.emit(cfg, blocked_fields())
        local payload = require("cjson").decode(_http_requests[1].body)
        assert.equal("ai-gateway", payload.index)
    end)

    it("logs warning on delivery error", function()
        _http_error = "connection refused"
        siem.emit(cfg, blocked_fields())
        assert.equal(1, #_log_calls)
        assert.match("connection refused", _log_calls[1])
    end)
end)

-- ─── Elasticsearch backend ──────────────────────────────────────────────────
describe("siem.emit: elasticsearch backend", function()
    before_each(reset)

    it("POSTs to <url>/<index>/_doc", function()
        siem.emit({
            type = "elasticsearch", url = "https://es.test:9200",
            index = "aig-logs", events = {"blocked"},
        }, blocked_fields())
        assert.equal(1, #_http_requests)
        assert.equal("https://es.test:9200/aig-logs/_doc", _http_requests[1].url)
    end)

    it("uses default index 'aig-logs' when index not set", function()
        siem.emit({
            type = "elasticsearch", url = "https://es.test:9200", events = {"blocked"},
        }, blocked_fields())
        assert.match("/aig%-logs/_doc$", _http_requests[1].url)
    end)

    it("sets Authorization: Basic header when credentials given", function()
        siem.emit({
            type = "elasticsearch", url = "https://es.test:9200",
            index = "aig-logs", username = "admin", password = "secret",
            events = {"blocked"},
        }, blocked_fields())
        local auth = _http_requests[1].headers["Authorization"]
        assert.truthy(auth)
        assert.match("^Basic ", auth)
    end)

    it("omits Authorization header when no credentials", function()
        siem.emit({
            type = "elasticsearch", url = "https://es.test:9200",
            index = "aig-logs", events = {"blocked"},
        }, blocked_fields())
        assert.is_nil(_http_requests[1].headers["Authorization"])
    end)

    it("body is the raw fields JSON", function()
        siem.emit({
            type = "elasticsearch", url = "https://es.test:9200",
            index = "aig-logs", events = {"blocked"},
        }, blocked_fields())
        local ok, body = pcall(require("cjson").decode, _http_requests[1].body)
        assert.truthy(ok)
        assert.equal("t1", body.tenant_id)
    end)
end)

-- ─── Vector backend ─────────────────────────────────────────────────────────
describe("siem.emit: vector backend", function()
    before_each(reset)

    it("POSTs raw fields JSON to configured url", function()
        siem.emit({ type = "vector", url = "http://vector.test:8080", events = {"blocked"} }, blocked_fields())
        assert.equal(1, #_http_requests)
        assert.equal("http://vector.test:8080", _http_requests[1].url)
        assert.equal("POST", _http_requests[1].method)
    end)

    it("does not set Authorization header", function()
        siem.emit({ type = "vector", url = "http://vector.test:8080", events = {"blocked"} }, blocked_fields())
        assert.is_nil(_http_requests[1].headers["Authorization"])
    end)

    it("body contains fields JSON", function()
        siem.emit({ type = "vector", url = "http://vector.test:8080", events = {"blocked"} }, blocked_fields())
        local ok, body = pcall(require("cjson").decode, _http_requests[1].body)
        assert.truthy(ok)
        assert.equal("gw1", body.gateway_id)
    end)
end)

-- ─── Syslog UDP/CEF backend ─────────────────────────────────────────────────
describe("siem.emit: syslog UDP + CEF", function()
    before_each(reset)

    local cfg = {
        type = "syslog", host = "siem.corp.com", port = 514,
        protocol = "udp", format = "cef", events = {"blocked"},
    }

    it("sends UDP datagram to configured host:port", function()
        siem.emit(cfg, blocked_fields())
        assert.equal(1, #_udp_sends)
        assert.equal("siem.corp.com", _udp_sends[1].host)
        assert.equal(514, _udp_sends[1].port)
    end)

    it("CEF message starts with 'CEF:0'", function()
        siem.emit(cfg, blocked_fields())
        assert.match("^CEF:0", _udp_sends[1].msg)
    end)

    it("CEF message contains product name", function()
        siem.emit(cfg, blocked_fields())
        assert.match("AI%-Gateway", _udp_sends[1].msg)
    end)

    it("CEF message contains blocked_by value", function()
        siem.emit(cfg, blocked_fields())
        assert.match("cs1=guardrail", _udp_sends[1].msg)
    end)

    it("defaults to UDP when protocol absent", function()
        local c2 = { type = "syslog", host = "h", port = 514, format = "cef", events = {"blocked"} }
        siem.emit(c2, blocked_fields())
        assert.equal(1, #_udp_sends)
        assert.equal(0, #_tcp_sends)
    end)
end)

-- ─── Syslog TCP backend ──────────────────────────────────────────────────────
describe("siem.emit: syslog TCP + RFC5424", function()
    before_each(reset)

    it("sends TCP message to configured host:port", function()
        siem.emit({
            type = "syslog", host = "siem.corp.com", port = 6514,
            protocol = "tcp", format = "rfc5424", events = {"blocked"},
        }, blocked_fields())
        assert.equal(1, #_tcp_sends)
        assert.equal("siem.corp.com", _tcp_sends[1].host)
        assert.equal(6514, _tcp_sends[1].port)
    end)

    it("RFC5424 message starts with '<' priority", function()
        siem.emit({
            type = "syslog", host = "h", port = 514,
            protocol = "tcp", format = "rfc5424", events = {"blocked"},
        }, blocked_fields())
        assert.match("^<%d+>", _tcp_sends[1].msg)
    end)

    it("TCP message is newline-terminated", function()
        siem.emit({
            type = "syslog", host = "h", port = 514,
            protocol = "tcp", format = "cef", events = {"blocked"},
        }, blocked_fields())
        assert.match("\n$", _tcp_sends[1].msg)
    end)
end)
