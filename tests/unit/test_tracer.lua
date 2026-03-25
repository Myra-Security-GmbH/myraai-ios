-- tests/unit/test_tracer.lua
-- Unit tests for observability/tracer.lua
-- Run with: resty tests/runner.lua tests/unit/test_tracer.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls   = {}
local _timer_calls = {}
local _now_val     = 1700000000.0

_G.ngx = {
    log  = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    now  = function() return _now_val end,
    WARN = 4,
    ERR  = 3,
    INFO = 2,
    var  = { http_traceparent = nil },
    timer = {
        at = function(delay, fn, ...)
            local args = {...}
            _timer_calls[#_timer_calls+1] = { delay = delay, fn = fn, args = args }
            fn(nil, (table.unpack or unpack)(args))
            return true, nil
        end,
    },
    status = 200,
}

package.path = "/home/sas/work/ai-gateway/src/?.lua;" ..
               "/home/sas/work/ai-gateway/src/?/init.lua;" ..
               package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- Clear any stubs from previously loaded test files
for _, n in ipairs({ "observability.tracer", "resty.http", "resty.random", "resty.string", "utils.json" }) do
    package.loaded[n]  = nil
    package.preload[n] = nil
end

-- ─── module stubs ──────────────────────────────────────────────────────────

local _http_requests = {}
local _http_error    = nil
local _http_status   = 200

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
                    return { status = _http_status, body = "" }
                end,
            }
        end,
    }
end

-- resty.random stub — returns deterministic bytes
package.preload["resty.random"] = function()
    local _seq = 0
    return {
        bytes = function(n)
            local out = {}
            for i = 1, n do
                _seq = (_seq + 1) % 256
                out[i] = string.char(_seq)
            end
            return table.concat(out)
        end,
    }
end

-- resty.string stub
package.preload["resty.string"] = function()
    return {
        to_hex = function(s)
            local h = ""
            for i = 1, #s do
                h = h .. string.format("%02x", s:byte(i))
            end
            return h
        end,
    }
end

-- utils.json stub — wraps cjson
local cjson = require("cjson.safe")
package.preload["utils.json"] = function()
    return { encode = cjson.encode, decode = cjson.decode }
end

local function reload()
    _log_calls   = {}
    _timer_calls = {}
    _http_requests = {}
    _http_error    = nil
    _http_status   = 200
    _now_val       = 1700000000.0
    ngx.var  = { http_traceparent = nil }
    ngx.status = 200
    for _, n in ipairs({ "observability.tracer", "resty.http", "resty.random", "resty.string", "utils.json" }) do
        package.loaded[n] = nil
    end
end

reload()
local tracer = require("observability.tracer")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A valid 128-bit trace_id (32 hex) and 64-bit span_id (16 hex)
local VALID_TRACE_ID  = "4bf92f3577b34da6a3ce929d0e0e4736"
local VALID_SPAN_ID   = "00f067aa0ba902b7"
local VALID_TRACEPARENT = "00-" .. VALID_TRACE_ID .. "-" .. VALID_SPAN_ID .. "-01"

local function base_ctx(overrides)
    local c = {
        otel_trace_id      = VALID_TRACE_ID,
        otel_root_span_id  = VALID_SPAN_ID,
        otel_parent_span_id = nil,
        otel_start_ns      = math.floor(1700000000.0 * 1e9),
        provider           = "openai",
        model              = "gpt-4o",
        input_tokens       = 100,
        output_tokens      = 50,
        cost_usd           = 0.003,
        cache_hit          = false,
        tenant_id          = "tenant-1",
        gateway_id         = "gw-1",
        provider_status    = 200,
        log_fields         = {},
        upstream_t_start   = 1700000000.1,
        upstream_latency_ms = 400,
        upstream_attempts  = 1,
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function tracing_cfg(overrides)
    local c = {
        otlp_endpoint = "http://otel-collector:4318",
        service_name  = "ai-gateway-test",
        headers       = {},
        sample_rate   = 1.0,
        include_bodies = false,
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

-- ============================================================================
-- parse_traceparent
-- ============================================================================

describe("parse_traceparent", function()

    it("returns nil for nil input", function()
        assert.is_nil(tracer._parse_traceparent(nil))
    end)

    it("returns nil for empty string", function()
        assert.is_nil(tracer._parse_traceparent(""))
    end)

    it("parses valid traceparent", function()
        local r = tracer._parse_traceparent(VALID_TRACEPARENT)
        assert.not_nil(r)
        assert.equal(VALID_TRACE_ID, r.trace_id)
        assert.equal(VALID_SPAN_ID,  r.parent_span_id)
    end)

    it("returns nil for wrong version (ff reserved)", function()
        local h = "ff-" .. VALID_TRACE_ID .. "-" .. VALID_SPAN_ID .. "-01"
        assert.is_nil(tracer._parse_traceparent(h))
    end)

    it("returns nil when trace_id is all zeros", function()
        local h = "00-" .. ("0"):rep(32) .. "-" .. VALID_SPAN_ID .. "-01"
        assert.is_nil(tracer._parse_traceparent(h))
    end)

    it("returns nil when parent_id is all zeros", function()
        local h = "00-" .. VALID_TRACE_ID .. "-" .. ("0"):rep(16) .. "-01"
        assert.is_nil(tracer._parse_traceparent(h))
    end)

    it("returns nil for wrong segment lengths", function()
        assert.is_nil(tracer._parse_traceparent("00-abc-def-01"))
    end)

    it("returns nil for non-hex characters", function()
        local h = "00-" .. ("g"):rep(32) .. "-" .. VALID_SPAN_ID .. "-01"
        assert.is_nil(tracer._parse_traceparent(h))
    end)

end)

-- ============================================================================
-- gen_id
-- ============================================================================

describe("gen_id", function()

    before_each(function() reload(); tracer = require("observability.tracer") end)

    it("returns 16 hex chars from 8 bytes", function()
        local id = tracer._gen_id(8)
        assert.equal(16, #id)
        assert.truthy(id:match("^%x+$"), "not hex: " .. id)
    end)

    it("returns 32 hex chars from 16 bytes", function()
        local id = tracer._gen_id(16)
        assert.equal(32, #id)
        assert.truthy(id:match("^%x+$"), "not hex: " .. id)
    end)

end)

-- ============================================================================
-- M.traceparent
-- ============================================================================

describe("M.traceparent", function()

    it("returns W3C formatted traceparent", function()
        local ctx = base_ctx()
        local tp = tracer.traceparent(ctx)
        assert.equal("00-" .. VALID_TRACE_ID .. "-" .. VALID_SPAN_ID .. "-01", tp)
    end)

    it("returns nil when otel_trace_id is not set", function()
        local ctx = base_ctx()
        ctx.otel_trace_id = nil
        assert.is_nil(tracer.traceparent(ctx))
    end)

end)

-- ============================================================================
-- M.init
-- ============================================================================

describe("M.init", function()

    before_each(function()
        reload()
        tracer = require("observability.tracer")
    end)

    it("generates new IDs when no incoming traceparent", function()
        ngx.var.http_traceparent = nil
        local ctx = {}
        tracer.init(ctx)
        assert.not_nil(ctx.otel_trace_id)
        assert.not_nil(ctx.otel_root_span_id)
        assert.equal(32, #ctx.otel_trace_id)
        assert.equal(16, #ctx.otel_root_span_id)
        assert.is_nil(ctx.otel_parent_span_id)
    end)

    it("propagates trace_id from valid incoming traceparent", function()
        ngx.var.http_traceparent = VALID_TRACEPARENT
        local ctx = {}
        tracer.init(ctx)
        assert.equal(VALID_TRACE_ID, ctx.otel_trace_id)
        assert.equal(VALID_SPAN_ID,  ctx.otel_parent_span_id)
        -- root_span_id should be a NEW span ID (not the incoming one)
        assert.equal(16, #ctx.otel_root_span_id)
    end)

    it("generates new trace_id when incoming traceparent is invalid", function()
        ngx.var.http_traceparent = "garbage"
        local ctx = {}
        tracer.init(ctx)
        -- Should not be "garbage", should be a 32-hex ID
        assert.equal(32, #ctx.otel_trace_id)
    end)

    it("sets otel_start_ns as integer nanoseconds", function()
        ngx.var.http_traceparent = nil
        local ctx = {}
        tracer.init(ctx)
        assert.truthy(type(ctx.otel_start_ns) == "number")
        -- Should be around 1.7e18 (ns since epoch)
        assert.truthy(ctx.otel_start_ns > 1e18)
    end)

end)

-- ============================================================================
-- build_root_span
-- ============================================================================

describe("build_root_span", function()

    it("returns span with kind=2 (SERVER)", function()
        local span = tracer._build_root_span(base_ctx(), tracing_cfg())
        assert.equal(2, span.kind)
    end)

    it("sets name to 'inference'", function()
        local span = tracer._build_root_span(base_ctx(), tracing_cfg())
        assert.equal("inference", span.name)
    end)

    it("includes gen_ai.system attribute", function()
        local span = tracer._build_root_span(base_ctx({ provider = "anthropic" }), tracing_cfg())
        local found = false
        for _, a in ipairs(span.attributes) do
            if a.key == "gen_ai.system" then
                found = true
                assert.equal("anthropic", a.value.stringValue)
            end
        end
        assert.truthy(found, "gen_ai.system attribute missing")
    end)

    it("includes all GenAI semantic convention attributes", function()
        local span = tracer._build_root_span(base_ctx(), tracing_cfg())
        local keys = {}
        for _, a in ipairs(span.attributes) do keys[a.key] = true end
        for _, expected in ipairs({
            "gen_ai.system", "gen_ai.request.model",
            "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens",
            "gen_ai.request.cost_usd",
            "http.status_code", "aig.tenant_id", "aig.gateway_id",
            "aig.cached", "aig.blocked",
        }) do
            assert.truthy(keys[expected], "missing attribute: " .. expected)
        end
    end)

    it("sets status code=2 (ERROR) when blocked", function()
        local ctx = base_ctx({ log_fields = { blocked_by = "guardrail", block_reason = "test" } })
        local span = tracer._build_root_span(ctx, tracing_cfg())
        assert.equal(2, span.status.code)
    end)

    it("sets status code=0 (OK) for successful request", function()
        local span = tracer._build_root_span(base_ctx(), tracing_cfg())
        assert.equal(0, span.status.code)
    end)

    it("sets parentSpanId when ctx.otel_parent_span_id is set", function()
        local ctx = base_ctx({ otel_parent_span_id = "aabbccddeeff0011" })
        local span = tracer._build_root_span(ctx, tracing_cfg())
        assert.equal("aabbccddeeff0011", span.parentSpanId)
    end)

    it("omits parentSpanId when otel_parent_span_id is nil", function()
        local span = tracer._build_root_span(base_ctx(), tracing_cfg())
        assert.is_nil(span.parentSpanId)
    end)

    it("sets status code=2 when http status >= 500", function()
        local ctx = base_ctx({ provider_status = 503 })
        local span = tracer._build_root_span(ctx, tracing_cfg())
        assert.equal(2, span.status.code)
    end)

end)

-- ============================================================================
-- build_upstream_span
-- ============================================================================

describe("build_upstream_span", function()

    it("returns nil when ctx.upstream_t_start is not set", function()
        local ctx = base_ctx()
        ctx.upstream_t_start = nil
        assert.is_nil(tracer._build_upstream_span(ctx))
    end)

    it("returns span with kind=3 (CLIENT)", function()
        local span = tracer._build_upstream_span(base_ctx())
        assert.not_nil(span)
        assert.equal(3, span.kind)
    end)

    it("sets parentSpanId to root span ID", function()
        local ctx = base_ctx()
        local span = tracer._build_upstream_span(ctx)
        assert.equal(ctx.otel_root_span_id, span.parentSpanId)
    end)

    it("sets name to upstream.<provider>", function()
        local span = tracer._build_upstream_span(base_ctx({ provider = "anthropic" }))
        assert.equal("upstream.anthropic", span.name)
    end)

    it("includes aig.upstream_latency_ms attribute", function()
        local ctx = base_ctx({ upstream_latency_ms = 350 })
        local span = tracer._build_upstream_span(ctx)
        local found = false
        for _, a in ipairs(span.attributes) do
            if a.key == "aig.upstream_latency_ms" then
                found = true
                assert.equal(350, a.value.intValue)
            end
        end
        assert.truthy(found, "aig.upstream_latency_ms missing")
    end)

    it("includes fallback attributes when fallback_provider is set", function()
        local ctx = base_ctx({
            fallback_provider = "anthropic",
            fallback_model    = "claude-3-5-sonnet",
        })
        local span = tracer._build_upstream_span(ctx)
        local keys = {}
        for _, a in ipairs(span.attributes) do keys[a.key] = true end
        assert.truthy(keys["aig.fallback_provider"])
        assert.truthy(keys["aig.fallback_model"])
    end)

    it("omits fallback attributes when fallback_provider is nil", function()
        local span = tracer._build_upstream_span(base_ctx())
        for _, a in ipairs(span.attributes) do
            assert.not_equal("aig.fallback_provider", a.key)
        end
    end)

end)

-- ============================================================================
-- build_otlp_payload
-- ============================================================================

describe("build_otlp_payload", function()

    it("wraps spans in resourceSpans array", function()
        local spans = { { name = "inference" } }
        local payload = tracer._build_otlp_payload("my-svc", spans)
        assert.not_nil(payload.resourceSpans)
        assert.equal(1, #payload.resourceSpans)
    end)

    it("sets service.name resource attribute", function()
        local payload = tracer._build_otlp_payload("my-svc", {})
        local rs = payload.resourceSpans[1]
        local found = false
        for _, a in ipairs(rs.resource.attributes) do
            if a.key == "service.name" then
                found = true
                assert.equal("my-svc", a.value.stringValue)
            end
        end
        assert.truthy(found, "service.name attribute missing")
    end)

    it("places spans under scopeSpans", function()
        local spans = { { name = "s1" }, { name = "s2" } }
        local payload = tracer._build_otlp_payload("svc", spans)
        local ss = payload.resourceSpans[1].scopeSpans
        assert.equal(1, #ss)
        assert.equal(2, #ss[1].spans)
    end)

end)

-- ============================================================================
-- M.emit
-- ============================================================================

describe("M.emit", function()

    before_each(function()
        reload()
        tracer = require("observability.tracer")
    end)

    it("is a no-op when otlp_endpoint is absent", function()
        local cfg = tracing_cfg()
        cfg.otlp_endpoint = nil
        tracer.emit(base_ctx(), cfg)
        assert.equal(0, #_timer_calls)
        assert.equal(0, #_http_requests)
    end)

    it("is a no-op when otel_trace_id is not set", function()
        local ctx = base_ctx()
        ctx.otel_trace_id = nil
        tracer.emit(ctx, tracing_cfg())
        assert.equal(0, #_timer_calls)
    end)

    it("POSTs to {endpoint}/v1/traces", function()
        tracer.emit(base_ctx(), tracing_cfg())
        assert.equal(1, #_http_requests)
        assert.equal("http://otel-collector:4318/v1/traces", _http_requests[1].url)
    end)

    it("sets Content-Type: application/json", function()
        tracer.emit(base_ctx(), tracing_cfg())
        assert.equal(1, #_http_requests)
        assert.equal("application/json", _http_requests[1].headers["Content-Type"])
    end)

    it("fires timer with delay 0", function()
        tracer.emit(base_ctx(), tracing_cfg())
        assert.equal(1, #_timer_calls)
        assert.equal(0, _timer_calls[1].delay)
    end)

    it("includes both root and upstream spans when upstream was called", function()
        tracer.emit(base_ctx(), tracing_cfg())
        local req = _http_requests[1]
        local payload = cjson.decode(req.body)
        local spans = payload.resourceSpans[1].scopeSpans[1].spans
        assert.equal(2, #spans)
    end)

    it("includes only root span when upstream_t_start is nil", function()
        local ctx = base_ctx()
        ctx.upstream_t_start = nil
        tracer.emit(ctx, tracing_cfg())
        local payload = cjson.decode(_http_requests[1].body)
        local spans = payload.resourceSpans[1].scopeSpans[1].spans
        assert.equal(1, #spans)
    end)

    it("skips export when sample_rate is 0", function()
        -- seed math.random for determinism
        math.randomseed(42)
        -- sample_rate = 0 means never export
        for _ = 1, 20 do
            reload()
            tracer = require("observability.tracer")
            tracer.emit(base_ctx(), tracing_cfg({ sample_rate = 0 }))
        end
        assert.equal(0, #_http_requests)
    end)

    it("merges extra headers into OTLP request", function()
        local cfg = tracing_cfg({ headers = { ["X-Custom-Header"] = "val123" } })
        tracer.emit(base_ctx(), cfg)
        assert.equal("val123", _http_requests[1].headers["X-Custom-Header"])
    end)

    it("logs WARN on delivery error, does not throw", function()
        _http_error = "connection refused"
        assert.has_no.errors(function()
            tracer.emit(base_ctx(), tracing_cfg())
        end)
        local found = false
        for _, m in ipairs(_log_calls) do
            if m:find("delivery failed") then found = true end
        end
        assert.truthy(found, "expected WARN log on delivery error")
    end)

    it("logs WARN when collector returns 4xx, does not throw", function()
        _http_status = 401
        assert.has_no.errors(function()
            tracer.emit(base_ctx(), tracing_cfg())
        end)
        local found = false
        for _, m in ipairs(_log_calls) do
            if m:find("401") then found = true end
        end
        assert.truthy(found, "expected WARN log on 4xx response")
    end)

end)
