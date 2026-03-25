-- observability/tracer.lua — OpenTelemetry distributed tracing
--
-- Emits W3C-compliant OTLP/HTTP JSON spans to an external OTel collector.
-- Coexists with the internal playground trace system — they are independent.
--
-- Usage:
--   tracer.init(ctx)          → parse incoming traceparent, generate IDs
--   tracer.traceparent(ctx)   → "00-<trace_id>-<span_id>-01" for forwarding
--   tracer.emit(ctx, cfg)     → async export spans to OTLP endpoint
--
-- Config (gateway_config.tracing):
--   otlp_endpoint  string  — e.g. "http://otel-collector:4318"
--   service_name   string  — default "ai-gateway"
--   headers        table   — extra HTTP headers for the OTLP request
--   sample_rate    number  — 0.0–1.0, default 1.0 (always export)
--   include_bodies boolean — include prompt/response text in span attributes

local http    = require("resty.http")
local random  = require("resty.random")
local str_lib = require("resty.string")
local json    = require("utils.json")

local M = {}

-- ---------------------------------------------------------------------------
-- ID generation
-- ---------------------------------------------------------------------------

-- Generate a random hex ID: bytes=8 → 16 hex chars (span ID)
--                           bytes=16 → 32 hex chars (trace ID)
local function gen_id(bytes)
    return str_lib.to_hex(random.bytes(bytes))
end

-- ---------------------------------------------------------------------------
-- W3C traceparent parsing
-- ---------------------------------------------------------------------------

-- Parse a W3C traceparent header.
-- Returns {trace_id, parent_span_id, flags} or nil on any parse error.
local function parse_traceparent(header)
    if not header or header == "" then return nil end
    -- Format: 00-<32hex>-<16hex>-<2hex>
    local ver, trace_id, parent_id, flags =
        header:match("^(%x%x)%-(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%-(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%-(%x%x)$")
    if not ver then return nil end
    if ver == "ff" then return nil end  -- reserved version
    if trace_id == ("0"):rep(32) then return nil end  -- all-zeros trace_id invalid
    if parent_id == ("0"):rep(16) then return nil end  -- all-zeros parent_id invalid
    return { trace_id = trace_id, parent_span_id = parent_id, flags = flags }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Initialise OTel context for this request.
-- Sets ctx.otel_trace_id, ctx.otel_root_span_id, ctx.otel_parent_span_id, ctx.otel_start_ns.
-- Must be called early in the access phase (from request_id.lua).
function M.init(ctx)
    local incoming = parse_traceparent(ngx.var.http_traceparent)
    ctx.otel_trace_id      = (incoming and incoming.trace_id)      or gen_id(16)
    ctx.otel_root_span_id  = gen_id(8)
    ctx.otel_parent_span_id = incoming and incoming.parent_span_id  -- may be nil
    ctx.otel_start_ns      = math.floor(ngx.now() * 1e9)
end

-- Return a W3C traceparent header value for forwarding to upstream providers.
function M.traceparent(ctx)
    if not ctx.otel_trace_id then return nil end
    return string.format("00-%s-%s-01", ctx.otel_trace_id, ctx.otel_root_span_id)
end

-- ---------------------------------------------------------------------------
-- Span builders
-- ---------------------------------------------------------------------------

local function attr_str(key, val)
    return { key = key, value = { stringValue = tostring(val) } }
end

local function attr_int(key, val)
    return { key = key, value = { intValue = math.floor(val) } }
end

local function attr_float(key, val)
    return { key = key, value = { doubleValue = val } }
end

local function attr_bool(key, val)
    return { key = key, value = { boolValue = val == true } }
end

-- Build the root (SERVER) span covering the full request lifecycle.
local function build_root_span(ctx, cfg)
    local now_ns   = math.floor(ngx.now() * 1e9)
    local start_ns = ctx.otel_start_ns or now_ns

    local status = ctx.provider_status or ngx.status or 0
    local blocked = (ctx.log_fields and ctx.log_fields.blocked_by) ~= nil

    local attrs = {
        attr_str("gen_ai.system",               ctx.provider or "unknown"),
        attr_str("gen_ai.request.model",        ctx.model    or "unknown"),
        attr_int("gen_ai.usage.input_tokens",   ctx.input_tokens  or 0),
        attr_int("gen_ai.usage.output_tokens",  ctx.output_tokens or 0),
        attr_float("gen_ai.request.cost_usd",   ctx.cost_usd      or 0),
        attr_int("http.status_code",            status),
        attr_str("aig.tenant_id",               ctx.tenant_id  or ""),
        attr_str("aig.gateway_id",              ctx.gateway_id or ""),
        attr_bool("aig.cached",                 ctx.cache_hit == true),
        attr_bool("aig.blocked",                blocked),
    }

    if ctx.log_fields and ctx.log_fields.blocked_by then
        attrs[#attrs + 1] = attr_str("aig.blocked_by", ctx.log_fields.blocked_by)
    end
    if ctx.upstream_attempts and ctx.upstream_attempts > 0 then
        attrs[#attrs + 1] = attr_int("aig.upstream_attempts", ctx.upstream_attempts)
    end
    if cfg.include_bodies and ctx.input_tokens then
        -- Only include token counts, not raw bodies, unless include_bodies is explicitly set
        attrs[#attrs + 1] = attr_int("aig.request_size_bytes", ctx.request_size_bytes or 0)
    end

    local span = {
        traceId             = ctx.otel_trace_id,
        spanId              = ctx.otel_root_span_id,
        name                = "inference",
        kind                = 2,  -- SPAN_KIND_SERVER
        startTimeUnixNano   = tostring(start_ns),
        endTimeUnixNano     = tostring(now_ns),
        attributes          = attrs,
        status              = { code = (status >= 500 or blocked) and 2 or 0 },
    }
    if ctx.otel_parent_span_id then
        span.parentSpanId = ctx.otel_parent_span_id
    end
    return span
end

-- Build the upstream (CLIENT) child span for the provider call.
-- Returns nil when no upstream call was made (e.g. cache hit, block before upstream).
local function build_upstream_span(ctx)
    if not ctx.upstream_t_start then return nil end

    local start_ns = math.floor(ctx.upstream_t_start * 1e9)
    local lat_ms   = ctx.upstream_latency_ms or 0
    local end_ns   = start_ns + math.floor(lat_ms * 1e6)

    local attrs = {
        attr_str("gen_ai.system",           ctx.provider or "unknown"),
        attr_str("gen_ai.request.model",    ctx.model    or "unknown"),
        attr_int("http.status_code",        ctx.provider_status or 0),
        attr_int("aig.upstream_latency_ms", lat_ms),
        attr_int("aig.upstream_attempts",   ctx.upstream_attempts or 1),
    }

    if ctx.fallback_provider then
        attrs[#attrs + 1] = attr_str("aig.fallback_provider", ctx.fallback_provider)
        attrs[#attrs + 1] = attr_str("aig.fallback_model",    ctx.fallback_model or "")
    end

    return {
        traceId           = ctx.otel_trace_id,
        spanId            = gen_id(8),
        parentSpanId      = ctx.otel_root_span_id,
        name              = "upstream." .. (ctx.provider or "unknown"),
        kind              = 3,   -- SPAN_KIND_CLIENT
        startTimeUnixNano = tostring(start_ns),
        endTimeUnixNano   = tostring(end_ns),
        attributes        = attrs,
        status            = { code = (ctx.provider_status or 0) >= 500 and 2 or 0 },
    }
end

-- Build the OTLP ResourceSpans payload.
local function build_otlp_payload(service_name, spans)
    return {
        resourceSpans = {
            {
                resource = {
                    attributes = {
                        attr_str("service.name",    service_name or "ai-gateway"),
                        attr_str("telemetry.sdk.name",     "ai-gateway-lua"),
                        attr_str("telemetry.sdk.language", "lua"),
                    },
                },
                scopeSpans = {
                    {
                        scope = {
                            name    = "ai-gateway",
                            version = "1.0",
                        },
                        spans = spans,
                    },
                },
            },
        },
    }
end

-- Async OTLP delivery callback (runs inside ngx.timer).
local function deliver(_, endpoint, extra_headers, payload_json)
    local httpc = http.new()
    httpc:set_timeout(5000)

    local headers = {
        ["Content-Type"] = "application/json",
    }
    if type(extra_headers) == "table" then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end

    local url = endpoint .. "/v1/traces"
    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = payload_json,
        headers = headers,
    })
    if err then
        ngx.log(ngx.WARN, "otel: delivery failed: ", tostring(err))
    elseif res and res.status >= 400 then
        ngx.log(ngx.WARN, "otel: collector returned ", res.status)
    end
end

-- Emit OTLP spans asynchronously. No-op when otlp_endpoint is absent or on error.
function M.emit(ctx, cfg)
    if not cfg or not cfg.otlp_endpoint then return end
    if not ctx.otel_trace_id then return end

    -- Sampling: skip export when random exceeds sample_rate
    local rate = cfg.sample_rate
    if type(rate) == "number" and rate < 1.0 then
        if math.random() > rate then return end
    end

    local spans = {}
    local root = build_root_span(ctx, cfg)
    spans[#spans + 1] = root

    local up = build_upstream_span(ctx)
    if up then spans[#spans + 1] = up end

    local payload = json.encode(build_otlp_payload(cfg.service_name, spans))
    if not payload then
        ngx.log(ngx.WARN, "otel: payload encode failed")
        return
    end

    local ok, err = ngx.timer.at(0, deliver, cfg.otlp_endpoint, cfg.headers, payload)
    if not ok then
        ngx.log(ngx.WARN, "otel: timer.at failed: ", tostring(err))
    end
end

-- Expose internals for unit testing
M._parse_traceparent   = parse_traceparent
M._gen_id              = gen_id
M._build_root_span     = build_root_span
M._build_upstream_span = build_upstream_span
M._build_otlp_payload  = build_otlp_payload

return M
