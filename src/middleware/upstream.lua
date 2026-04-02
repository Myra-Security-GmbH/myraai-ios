-- middleware/upstream.lua — call the upstream provider with retry + fallback
--
-- Flow:
--   1. Build provider-specific request
--   2. Call provider HTTP endpoint
--   3. On failure or 5xx: retry up to gateway_config.retry_count times,
--      then try each fallback in ctx.fallback_chain
--   4. For streaming (SSE): forward chunks to client, accumulate token counts
--   5. For non-streaming: set ctx.response_body, ctx.provider_status
--   6. On all-providers-failed: return 502

local providers  = require("providers")
local http_util  = require("utils.http")
local errors     = require("core.errors")
local json       = require("utils.json")
local state      = require("state")
local thinking   = require("utils.thinking")
local trace      = require("utils.trace")

local M = {}

-- Maximum bytes to capture from a provider error response body for logging.
local MAX_ERR_BODY = 16384

-- Buffer up to max_bytes from a reader function (or return the string as-is).
-- Any remainder is drained so the connection can be returned to the pool.
local function read_body_str(body, max_bytes)
    max_bytes = max_bytes or MAX_ERR_BODY
    if type(body) ~= "function" then
        local s = tostring(body or "")
        if #s > max_bytes then return s:sub(1, max_bytes) .. " [truncated]" end
        return s
    end
    local parts, total = {}, 0
    while total < max_bytes do
        local chunk = body(math.min(8192, max_bytes - total))
        if not chunk or chunk == "" then break end
        parts[#parts + 1] = chunk
        total = total + #chunk
    end
    -- drain the rest so the connection can be reused
    while true do
        local chunk = body(8192)
        if not chunk or chunk == "" then break end
    end
    local s = table.concat(parts)
    if total >= max_bytes then s = s .. " [truncated]" end
    return s
end

-- Return a copy of a headers table with sensitive values replaced.
local SENSITIVE_HDR = {
    ["authorization"]  = true,
    ["x-api-key"]      = true,
    ["x-goog-api-key"] = true,
    ["api-key"]        = true,
}
local function redact_headers(headers)
    if type(headers) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(headers) do
        out[k] = SENSITIVE_HDR[k:lower()] and "[REDACTED]" or v
    end
    return out
end

-- Emit a single structured log line with every available detail about a
-- non-200 provider response or connection failure.
local function log_provider_error(req_ctx, res, fields)
    -- fields: {attempt, provider, model, latency_ms, resp_body, error, event}
    local entry = {
        event          = fields.event or "upstream_error",
        attempt        = fields.attempt,
        provider       = fields.provider,
        model          = fields.model,
        latency_ms     = fields.latency_ms,
        error          = fields.error,
        -- full request context
        url            = req_ctx and req_ctx.url,
        req_headers    = req_ctx and req_ctx.req_headers,
        req_body       = req_ctx and req_ctx.req_body,
        -- full response context
        resp_status    = res and res.status,
        resp_headers   = res and res.headers,
        resp_body      = fields.resp_body,
    }
    local level = (res and res.status and res.status >= 500) and ngx.ERR or ngx.WARN
    ngx.log(level, "[upstream_error] ", json.encode(entry))
end

-- Sleep with jittered exponential back-off between retries.
-- Respects Retry-After (seconds) and Retry-After-Ms (milliseconds) response headers.
local function backoff_sleep(try, headers)
    local delay_ms
    if headers then
        local ra_ms = tonumber(headers["retry-after-ms"] or headers["x-ratelimit-reset-after-ms"])
        local ra    = tonumber(headers["retry-after"])
        if ra_ms then
            delay_ms = ra_ms
        elseif ra then
            delay_ms = ra * 1000
        end
    end
    if not delay_ms then
        -- Jittered exponential: 500ms × 2^try, capped at 30 s, ±25% jitter
        local base = math.min(500 * (2 ^ try), 30000)
        delay_ms   = base * (0.75 + math.random() * 0.5)
    end
    delay_ms = math.min(delay_ms, 30000)
    ngx.log(ngx.INFO, "upstream: retry backoff ", math.floor(delay_ms), "ms (try=", try, ")")
    ngx.sleep(delay_ms / 1000)
end

-- Attempt a single call to one provider+model. Returns response table or nil, err.
local function call_provider(ctx, provider_name, model, is_streaming)
    local provider_mod, err = providers.get(provider_name)
    if not provider_mod then
        return nil, "provider load: " .. err
    end

    -- Temporarily override ctx provider/model for URL/header building
    local orig_provider = ctx.provider
    local orig_model    = ctx.model
    ctx.provider = provider_name
    ctx.model    = model

    local url     = provider_mod.base_url(ctx)
    -- Allow per-gateway base URL override (used by tests to point at mock provider)
    local overrides = ctx.gateway_config.provider_base_urls
    if overrides and overrides[provider_name] then
        local path = url:match("https?://[^/]+(/.*)") or "/"
        url = overrides[provider_name] .. path
    end
    local headers = provider_mod.build_headers(ctx, ctx.provider_api_key)
    -- Forward W3C traceparent to upstream provider for end-to-end trace correlation
    if ctx.otel_trace_id then
        local ok, tracer = pcall(require, "observability.tracer")
        if ok then headers["traceparent"] = tracer.traceparent(ctx) end
    end
    local body    = provider_mod.build_request(ctx)

    ctx.provider = orig_provider
    ctx.model    = orig_model

    -- Capture request context for error logging (headers redacted for security)
    local req_ctx = {
        url         = url,
        req_headers = redact_headers(headers),
        req_body    = body,
    }

    local status, resp_headers, body_or_reader, call_err, httpc =
        http_util.request({
            method     = "POST",
            url        = url,
            headers    = headers,
            body       = body,
            timeout_ms = ctx.rule_timeout_ms or ctx.gateway_config.timeout_ms or 60000,
            stream     = is_streaming,
        })

    if call_err then
        return nil, "http: " .. call_err, req_ctx
    end

    return {
        status        = status,
        headers       = resp_headers,
        body          = body_or_reader,  -- string if non-stream, reader if stream
        httpc         = httpc,
        provider_name = provider_name,
        provider_mod  = provider_mod,
        url           = url,             -- for tracing (no auth key)
        req_ctx       = req_ctx,         -- for error logging
    }, nil, req_ctx
end

-- #5: Shared SSE line extractor used by both streaming handlers.
-- Appends chunk to buf, extracts all complete \n-terminated lines, calls
-- on_parsed(result) for each non-nil parse_sse_chunk result.
-- #2: parse_sse_chunk is called inside pcall so a malformed chunk cannot
-- panic the worker and leave the client connection in an unknown state.
-- Returns the updated buf (incomplete last fragment, kept for next call).
local function drain_sse_buf(buf, chunk, provider_mod, on_parsed)
    buf = buf .. chunk
    local pos = 1
    while true do
        local nl = buf:find("\n", pos, true)
        if not nl then return buf:sub(pos) end
        local line = buf:sub(pos, nl - 1):gsub("\r$", "")
        pos = nl + 1
        local ok, result = pcall(provider_mod.parse_sse_chunk, line)
        if ok and result then
            on_parsed(result)
        elseif not ok then
            ngx.log(ngx.WARN, "[upstream] parse_sse_chunk panic on line=",
                    line:sub(1, 80), " err=", tostring(result))
        end
    end
end

-- Stream SSE from provider → client for compat requests.
-- Converts provider-native SSE (Anthropic, Gemini, etc.) to OpenAI
-- chat.completion.chunk format so any OpenAI-compatible client works.
local function handle_compat_streaming(ctx, res)
    -- web_search middleware may have already flushed headers (aig_status event).
    -- OpenResty silently ignores ngx.header/ngx.status assignments once headers
    -- are sent, so guard them explicitly to avoid confusion.
    if not ngx.headers_sent then
        ngx.status = 200
        ngx.header["Content-Type"]      = "text/event-stream"
        ngx.header["Cache-Control"]     = "no-cache"
        ngx.header["X-Accel-Buffering"] = "no"
        ngx.header["X-AIG-Provider"]    = res.provider_name
        ngx.header["X-AIG-Cache"]       = "MISS"
    end

    local reader       = res.body
    local provider_mod = res.provider_mod
    local buf          = ""
    local chat_id      = "chatcmpl-" .. (ctx.request_id or "aig")
    local model        = ctx.model
    local input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens = 0, 0, 0, 0
    local first_chunk_seen = false
    local done_sent        = false
    local stream_errored   = false  -- #8: track mid-stream read failures
    local in_think         = false  -- stateful <think> block tracker
    local stop_reason_seen = nil    -- accumulated from message_delta before message_stop fires
    -- #1: table accumulator avoids O(n²) string copies for large responses
    local acc_parts        = {}
    -- Diagnostics: count raw bytes and read() calls for truncation logging
    local bytes_read       = 0
    local read_calls       = 0
    local read_timeout_ms  = ctx.rule_timeout_ms or (ctx.gateway_config and ctx.gateway_config.timeout_ms) or 300000
    local stream_start_ms  = ngx.now() * 1000

    -- Initial role delta (mirrors OpenAI behaviour).
    -- Skipped when web_search already flushed an aig_status chunk — the client
    -- handles the stream without it; the role chunk is cosmetic only.
    if not ngx.headers_sent then
        local role_line = "data: " .. json.encode({
            id      = chat_id,
            object  = "chat.completion.chunk",
            model   = model,
            choices = {{ index = 0, delta = { role = "assistant", content = "" },
                         finish_reason = json.null }},
        }) .. "\n\n"
        ngx.print(role_line)
        ngx.flush(true)
    end

    -- #5: named closure captures all locals; defined once, not per-chunk
    local function on_compat_chunk(parsed)
        if parsed.input_tokens          then input_tokens          = parsed.input_tokens          end
        if parsed.output_tokens         then output_tokens         = parsed.output_tokens         end
        if parsed.cache_creation_tokens then cache_creation_tokens = parsed.cache_creation_tokens end
        if parsed.cache_read_tokens     then cache_read_tokens     = parsed.cache_read_tokens     end

        -- Accumulate stop_reason from message_delta — it arrives in an earlier
        -- chunk than message_stop (parsed.done), so we must capture it here.
        if parsed.stop_reason then stop_reason_seen = parsed.stop_reason end

        -- When the model starts a tool-use block, forward the tool name so the
        -- client can show a brief "Searching the web…" / "Using computer…" badge.
        if parsed.tool_name then
            local tool_evt = "data: " .. json.encode({ aig_tool_call = parsed.tool_name }) .. "\n\n"
            ngx.print(tool_evt)
            ngx.flush(true)
        end

        if parsed.done and not done_sent then
            -- Translate provider stop_reason → compat finish_reason.
            -- Normalise to "max_tokens" (not OpenAI's "length") so both old and
            -- new frontend builds recognise it and trigger auto-continue.
            -- Anthropic "end_turn" → "stop"; everything else passes through.
            local finish_reason = "stop"
            local sr = stop_reason_seen   -- use accumulated value, not parsed.stop_reason
            if sr == "max_tokens" or sr == "length" then
                finish_reason = "max_tokens"
            elseif sr and sr ~= "end_turn" and sr ~= "stop" and sr ~= "" then
                finish_reason = sr   -- pass through unknown reasons as-is
            end
            local finish_line = "data: " .. json.encode({
                id      = chat_id,
                object  = "chat.completion.chunk",
                model   = model,
                choices = {{ index = 0, delta = {}, finish_reason = finish_reason }},
            }) .. "\n\n"
            ngx.print(finish_line)
            ngx.flush(true)
            done_sent = true
        elseif parsed.delta and parsed.delta ~= "" then
            local visible
            visible, in_think = thinking.strip(parsed.delta, in_think)
            if visible and visible ~= "" then
                local delta_line = "data: " .. json.encode({
                    id      = chat_id,
                    object  = "chat.completion.chunk",
                    model   = model,
                    choices = {{ index = 0, delta = { content = visible },
                                 finish_reason = json.null }},
                }) .. "\n\n"
                ngx.print(delta_line)
                ngx.flush(true)
                acc_parts[#acc_parts + 1] = visible  -- #1
            end
        end
    end

    while true do
        local chunk, err = reader(8192)
        read_calls = read_calls + 1
        if err then
            local elapsed_ms = math.floor(ngx.now() * 1000 - stream_start_ms)
            ngx.log(ngx.ERR,
                "[stream_truncated] compat read error after ", elapsed_ms, "ms"
                .. " | provider=", res.provider_name
                .. " model=", model
                .. " gateway=", tostring(ctx.gateway_id)
                .. " request_id=", tostring(ctx.request_id)
                .. " bytes_read=", bytes_read
                .. " read_calls=", read_calls
                .. " content_chars=", #table.concat(acc_parts)
                .. " output_tokens=", output_tokens
                .. " done_sent=", tostring(done_sent)
                .. " read_timeout_ms=", read_timeout_ms
                .. " err=", err)
            stream_errored = true  -- #8
            break
        end
        if not chunk then break end
        if chunk ~= "" then
            bytes_read = bytes_read + #chunk
        end

        if not first_chunk_seen and chunk ~= "" then
            first_chunk_seen = true
            ctx.time_to_first_token_ms = math.floor(ngx.now() * 1000 - ctx.start_ms)
        end

        -- #5: shared line parser with #2 pcall protection inside
        buf = drain_sse_buf(buf, chunk, provider_mod, on_compat_chunk)
    end

    local accumulated_content = table.concat(acc_parts)  -- #1
    local elapsed_total_ms = math.floor(ngx.now() * 1000 - stream_start_ms)

    -- Detect provider closing connection without sending a finish event (unexpected EOF).
    -- This is a different failure mode from a read error: the TCP connection closed
    -- cleanly but the provider never sent [DONE] or finish_reason.
    if not stream_errored and not done_sent then
        ngx.log(ngx.WARN,
            "[stream_truncated] provider closed connection without finish event (unexpected EOF)"
            .. " | provider=", res.provider_name
            .. " model=", model
            .. " gateway=", tostring(ctx.gateway_id)
            .. " request_id=", tostring(ctx.request_id)
            .. " elapsed_ms=", elapsed_total_ms
            .. " bytes_read=", bytes_read
            .. " content_chars=", #accumulated_content
            .. " output_tokens=", output_tokens
            .. " first_chunk_seen=", tostring(first_chunk_seen))
    elseif not stream_errored then
        ngx.log(ngx.ERR,
            "[stream_ok] compat stream completed cleanly"
            .. " | provider=", res.provider_name
            .. " model=", model
            .. " gateway=", tostring(ctx.gateway_id)
            .. " finish_reason=", tostring(stop_reason_seen)
            .. " elapsed_ms=", elapsed_total_ms
            .. " bytes_read=", bytes_read
            .. " content_chars=", #accumulated_content
            .. " output_tokens=", output_tokens)
    end

    -- #8: on read error emit an error-finish chunk so clients don't hang
    if stream_errored then
        ngx.print("data: " .. json.encode({
            id      = chat_id,
            object  = "chat.completion.chunk",
            model   = model,
            choices = {{ index = 0, delta = { content = "" },
                         finish_reason = "error" }},
        }) .. "\n\n")
        ngx.flush(true)
    end

    -- Send usage chunk so clients can display token counts in real-time
    -- (emitted before [DONE] following the OpenAI stream_options.include_usage convention)
    if input_tokens > 0 or output_tokens > 0 then
        local usage_obj = {
            prompt_tokens     = input_tokens,
            completion_tokens = output_tokens,
            total_tokens      = input_tokens + output_tokens,
        }
        if cache_creation_tokens > 0 then usage_obj.cache_creation_tokens = cache_creation_tokens end
        if cache_read_tokens     > 0 then usage_obj.cache_read_tokens     = cache_read_tokens     end
        local usage_line = "data: " .. json.encode({
            id     = chat_id,
            object = "chat.completion.chunk",
            model  = model,
            usage  = usage_obj,
        }) .. "\n\n"
        ngx.print(usage_line)
        ngx.flush(true)
    end

    trace.step(ctx, "leg2_response", {
        content_len   = #accumulated_content,
        content       = accumulated_content,
        input_tokens  = input_tokens,
        output_tokens = output_tokens,
        done_sent     = done_sent,
    })

    -- #8: only emit [DONE] when the stream completed without a read error
    if not stream_errored then
        ngx.print("data: [DONE]\n\n")
        ngx.flush(true)
    end

    trace.step(ctx, "response_delivered", {
        streaming      = true,
        compat         = true,
        input_tokens   = input_tokens,
        output_tokens  = output_tokens,
        content_length = #accumulated_content,
        errored        = stream_errored,
    })
    trace.done(ctx, stream_errored and "error" or "done")

    if res.httpc then res.httpc:set_keepalive() end

    -- #7: update upstream_latency_ms to total stream duration, not just TTFB
    if ctx.upstream_t_start then
        ctx.upstream_latency_ms = math.floor((ngx.now() - ctx.upstream_t_start) * 1000)
    end

    ctx.input_tokens          = input_tokens
    ctx.output_tokens         = output_tokens
    ctx.cache_creation_tokens = cache_creation_tokens
    ctx.cache_read_tokens     = cache_read_tokens
    ctx.is_streaming          = true
    ctx.provider_status       = 200

    -- pii_protector: log raw streamed content for audit.
    if ctx.pii_token_map and accumulated_content ~= ""
       and ctx.gateway_config and ctx.gateway_config.log_payloads then
        ctx.log_fields = ctx.log_fields or {}
        ctx.log_fields.response_raw = accumulated_content
    end
end

-- Stream SSE from provider to client, accumulating token usage.
local function handle_streaming(ctx, res)
    if not ngx.headers_sent then
        ngx.status = 200
        ngx.header["Content-Type"]      = "text/event-stream"
        ngx.header["Cache-Control"]     = "no-cache"
        ngx.header["X-Accel-Buffering"] = "no"
        ngx.header["X-AIG-Provider"]    = res.provider_name
        ngx.header["X-AIG-Cache"]       = "MISS"
    end

    local reader       = res.body
    local provider_mod = res.provider_mod
    local buf          = ""
    local input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens = 0, 0, 0, 0
    local first_chunk_seen = false
    -- #1: table accumulator; only allocated when pii_protector is active
    local acc_parts = ctx.pii_token_map and {} or nil
    -- Diagnostics
    local bytes_read      = 0
    local read_calls      = 0
    local stream_errored  = false
    local read_timeout_ms = ctx.rule_timeout_ms or (ctx.gateway_config and ctx.gateway_config.timeout_ms) or 300000
    local stream_start_ms = ngx.now() * 1000

    -- #5: named closure; defined once outside the read loop
    local function on_stream_chunk(parsed)
        if parsed.input_tokens          then input_tokens          = parsed.input_tokens          end
        if parsed.output_tokens         then output_tokens         = parsed.output_tokens         end
        if parsed.cache_creation_tokens then cache_creation_tokens = parsed.cache_creation_tokens end
        if parsed.cache_read_tokens     then cache_read_tokens     = parsed.cache_read_tokens     end
        if acc_parts and parsed.delta and parsed.delta ~= "" then
            acc_parts[#acc_parts + 1] = parsed.delta  -- #1
        end
    end

    while true do
        local chunk, err = reader(8192)
        read_calls = read_calls + 1
        if err then
            local elapsed_ms = math.floor(ngx.now() * 1000 - stream_start_ms)
            ngx.log(ngx.ERR,
                "[stream_truncated] passthrough read error after ", elapsed_ms, "ms"
                .. " | provider=", res.provider_name
                .. " model=", model
                .. " gateway=", tostring(ctx.gateway_id)
                .. " request_id=", tostring(ctx.request_id)
                .. " bytes_read=", bytes_read
                .. " read_calls=", read_calls
                .. " output_tokens=", output_tokens
                .. " read_timeout_ms=", read_timeout_ms
                .. " err=", err)
            stream_errored = true
            break
        end
        if not chunk then break end
        if chunk ~= "" then
            bytes_read = bytes_read + #chunk
        end

        if not first_chunk_seen and chunk ~= "" then
            first_chunk_seen = true
            ctx.time_to_first_token_ms = math.floor(ngx.now() * 1000 - ctx.start_ms)
        end

        -- Forward to client immediately
        ngx.print(chunk)
        ngx.flush(true)

        -- #5: shared line parser with #2 pcall protection inside
        buf = drain_sse_buf(buf, chunk, provider_mod, on_stream_chunk)
    end

    local elapsed_total_ms = math.floor(ngx.now() * 1000 - stream_start_ms)

    if stream_errored then
        ngx.log(ngx.WARN,
            "[stream_truncated] passthrough stream ended with read error"
            .. " | provider=", res.provider_name
            .. " model=", model
            .. " gateway=", tostring(ctx.gateway_id)
            .. " elapsed_ms=", elapsed_total_ms
            .. " bytes_forwarded=", bytes_read
            .. " output_tokens=", output_tokens)
    else
        ngx.log(ngx.ERR,
            "[stream_ok] passthrough stream completed"
            .. " | provider=", res.provider_name
            .. " model=", model
            .. " gateway=", tostring(ctx.gateway_id)
            .. " elapsed_ms=", elapsed_total_ms
            .. " bytes_forwarded=", bytes_read
            .. " output_tokens=", output_tokens)
    end

    -- Return connection to pool
    if res.httpc then res.httpc:set_keepalive() end

    -- #7: update upstream_latency_ms to total stream duration, not just TTFB
    if ctx.upstream_t_start then
        ctx.upstream_latency_ms = math.floor((ngx.now() - ctx.upstream_t_start) * 1000)
    end

    ctx.input_tokens          = input_tokens
    ctx.output_tokens         = output_tokens
    ctx.cache_creation_tokens = cache_creation_tokens
    ctx.cache_read_tokens     = cache_read_tokens
    ctx.is_streaming          = true
    ctx.provider_status       = 200

    trace.step(ctx, "response_delivered", {
        streaming     = true,
        compat        = false,
        input_tokens  = input_tokens,
        output_tokens = output_tokens,
    })
    trace.done(ctx, "done")

    -- pii_protector: log raw streamed content for audit (response phase is skipped
    -- for streaming, so we capture here instead).
    if ctx.pii_token_map and acc_parts
       and ctx.gateway_config and ctx.gateway_config.log_payloads then
        ctx.log_fields = ctx.log_fields or {}
        ctx.log_fields.response_raw = table.concat(acc_parts)  -- #1
    end
end

-- Non-streaming response: buffer full body and parse.
local function handle_buffered(ctx, res)
    local provider_mod = res.provider_mod
    local body_str     = res.body  -- already a string from http_util

    local parsed, err = provider_mod.parse_response(body_str)
    if not parsed then
        return nil, "parse_response: " .. tostring(err)
    end

    -- For compat requests the client speaks OpenAI format, so convert the
    -- provider-native response back to an OpenAI chat.completion envelope.
    if ctx.is_compat then
        body_str = json.encode({
            id      = "chatcmpl-" .. (ctx.request_id or "aig"),
            object  = "chat.completion",
            model   = ctx.model,
            choices = {{
                index         = 0,
                message       = { role = "assistant", content = parsed.content },
                finish_reason = "stop",
            }},
            usage   = {
                prompt_tokens     = parsed.input_tokens,
                completion_tokens = parsed.output_tokens,
                total_tokens      = (parsed.input_tokens or 0) + (parsed.output_tokens or 0),
            },
        })
    end

    ctx.response_body         = body_str
    ctx.input_tokens          = parsed.input_tokens
    ctx.output_tokens         = parsed.output_tokens
    ctx.cache_creation_tokens = parsed.cache_creation_tokens or 0
    ctx.cache_read_tokens     = parsed.cache_read_tokens     or 0
    ctx.provider_status       = res.status
    ctx.is_streaming    = false
    return true
end

-- Single non-streaming provider call for use by the web_search middleware (Leg 1).
-- Runs the same retry + fallback logic as M.run().
-- Returns (body_str, http_status, err).  Does NOT modify ctx.response_body.
function M.call_one(ctx)
    local retry_count = ctx.gateway_config.retry_count or 2
    local cb          = require("core.circuit_breaker")
    local cb_cfg      = ctx.gateway_config.circuit_breaker

    local attempts = {{ provider = ctx.provider, model = ctx.model }}
    for _, fb in ipairs(ctx.fallback_chain or {}) do
        attempts[#attempts + 1] = fb
    end

    local last_err
    for attempt_idx, attempt in ipairs(attempts) do
        local provider_name = attempt.provider or ctx.provider
        local model         = attempt.model    or ctx.model

        if cb.check(ctx.gateway_id, provider_name, cb_cfg) == "deny" then
            last_err = "circuit_open:" .. provider_name
            goto co_continue
        end
        if provider_name ~= ctx.provider then
            local byok_vault = require("auth.byok")
            local key = byok_vault.get_key(ctx.gateway_id, provider_name)
            if not key then goto co_continue end
            ctx.provider_api_key = key
        end

        for _ = 0, (attempt_idx == 1 and retry_count or 0) do
            local t_call = ngx.now()  -- #4: track latency in call_one
            local res, err = call_provider(ctx, provider_name, model, false)
            local call_ms = math.floor((ngx.now() - t_call) * 1000)
            if not res then
                last_err = err
                cb.record_failure(ctx.gateway_id, provider_name, cb_cfg, nil,
                                  ctx.gateway_config.webhooks)
            elseif res.status >= 500 then
                last_err = "provider HTTP " .. res.status
                cb.record_failure(ctx.gateway_id, provider_name, cb_cfg, res.status,
                                  ctx.gateway_config.webhooks)
            else
                cb.record_success(ctx.gateway_id, provider_name, cb_cfg)
                -- #4: keep ctx consistent with the provider actually used
                ctx.provider = provider_name
                ctx.model    = model
                ctx.upstream_latency_ms = call_ms
                return res.body, res.status, nil
            end
        end
        ::co_continue::
    end
    return nil, nil, last_err or "all_providers_failed"
end

function M.run(ctx)
    -- web_search middleware sets this when it already handled the full response
    if ctx.web_search_done then return end

    -- pii_protector forces buffered mode for compat streaming requests so that
    -- the response phase can restore tokens before the client sees them.
    local is_streaming = ctx.request_body and ctx.request_body.stream == true
                         and not ctx.pii_force_buffered
    local retry_count  = ctx.gateway_config.retry_count or 2
    local cb           = require("core.circuit_breaker")
    local cb_cfg       = ctx.gateway_config.circuit_breaker

    -- Build attempt list: primary + fallbacks
    local attempts = {{ provider = ctx.provider, model = ctx.model }}
    for _, fb in ipairs(ctx.fallback_chain or {}) do
        attempts[#attempts + 1] = fb
    end

    local last_err
    local total_attempts = 0

    for attempt_idx, attempt in ipairs(attempts) do
        local provider_name = attempt.provider or ctx.provider
        local model         = attempt.model    or ctx.model

        -- Circuit breaker: skip this provider if its breaker is open
        if cb.check(ctx.gateway_id, provider_name, cb_cfg) == "deny" then
            ngx.log(ngx.INFO, "upstream: circuit open, skipping provider=", provider_name)
            last_err = "circuit_open:" .. provider_name
            goto continue
        end

        -- Swap BYOK key if fallback uses a different provider
        if provider_name ~= ctx.provider then
            local byok_vault = require("auth.byok")
            local key, k_err = byok_vault.get_key(ctx.gateway_id, provider_name)
            if not key then
                ngx.log(ngx.WARN, "upstream: no key for fallback provider ",
                        provider_name, ": ", k_err)
                goto continue
            end
            ctx.provider_api_key = key
        end

        local retries = (attempt_idx == 1) and retry_count or 0

        for try = 0, retries do
            if try > 0 then
                ngx.log(ngx.INFO, "upstream retry ", try, "/", retries,
                        " provider=", provider_name)
            end

            total_attempts = total_attempts + 1

            -- TRACE: what we are about to send to the provider
            trace.step(ctx, "upstream_request", {
                attempt    = total_attempts,
                provider   = provider_name,
                model      = model,
                streaming  = is_streaming,
                body_size  = ctx.raw_request_body and #ctx.raw_request_body or 0,
                timeout_ms = ctx.rule_timeout_ms or ctx.gateway_config.timeout_ms or 60000,
            })

            local t_call = ngx.now()
            local res, err, req_ctx = call_provider(ctx, provider_name, model, is_streaming)
            local call_ms = math.floor((ngx.now() - t_call) * 1000)

            if not res then
                last_err = err
                -- TRACE: call error
                trace.step(ctx, "upstream_error", {
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    error      = err,
                    latency_ms = call_ms,
                })
                log_provider_error(req_ctx, nil, {
                    event      = "connection_failed",
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    latency_ms = call_ms,
                    error      = err,
                })
                cb.record_failure(ctx.gateway_id, provider_name, cb_cfg, nil,
                              ctx.gateway_config.webhooks)
                goto next_try
            end

            -- 5xx from provider → retry
            if res.status >= 500 then
                last_err = "provider HTTP " .. res.status
                -- Buffer the error body (and implicitly drain) so we can log it
                -- and return the connection to the pool.
                local resp_body_5xx = read_body_str(res.body)
                if res.httpc then res.httpc:set_keepalive() end
                -- TRACE: call error
                trace.step(ctx, "upstream_error", {
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    error      = last_err,
                    latency_ms = call_ms,
                    resp_body  = resp_body_5xx,
                })
                log_provider_error(res.req_ctx, res, {
                    event      = "provider_5xx",
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    latency_ms = call_ms,
                    resp_body  = resp_body_5xx,
                })
                cb.record_failure(ctx.gateway_id, provider_name, cb_cfg, res.status,
                                  ctx.gateway_config.webhooks)
                goto next_try
            end

            -- 429 Too Many Requests → retry with back-off instead of passing through
            if res.status == 429 then
                last_err = "provider HTTP 429"
                -- Buffer body (also drains it) so we can log rate-limit details
                local resp_body_429 = read_body_str(res.body)
                if res.httpc then res.httpc:set_keepalive() end
                -- TRACE: call error
                trace.step(ctx, "upstream_error", {
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    error      = last_err,
                    latency_ms = call_ms,
                    resp_body  = resp_body_429,
                })
                log_provider_error(res.req_ctx, res, {
                    event      = "provider_429",
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    latency_ms = call_ms,
                    resp_body  = resp_body_429,
                })
                cb.record_failure(ctx.gateway_id, provider_name, cb_cfg, res.status,
                                  ctx.gateway_config.webhooks)
                goto next_try
            end

            -- 4xx from provider → pass through immediately (don't retry)
            -- The error body comes from the provider so forward it as-is.
            if res.status >= 400 then
                -- res.body may be a reader function (when client sent stream=true)
                -- even though the provider returned a plain JSON error. Buffer it.
                local body_str = read_body_str(res.body)
                if res.httpc then res.httpc:set_keepalive() end
                log_provider_error(res.req_ctx, res, {
                    event      = "provider_4xx",
                    attempt    = total_attempts,
                    provider   = provider_name,
                    model      = model,
                    latency_ms = call_ms,
                    resp_body  = body_str,
                })
                ctx.upstream_latency_ms = call_ms
                ctx.upstream_attempts   = total_attempts
                ctx.provider_request_id = res.headers and
                    (res.headers["x-request-id"] or res.headers["request-id"])
                ctx.provider        = provider_name
                ctx.model           = model
                ctx.response_body   = body_str
                ctx.provider_status = res.status
                ctx.is_streaming    = false
                ngx.status = res.status
                ngx.header["Content-Type"] = "application/json"
                ngx.header["X-AIG-Cache"]  = "MISS"
                ngx.header["X-AIG-Provider"] = provider_name
                ngx.header["X-AIG-Model"]    = model
                trace.step(ctx, "response_delivered", {
                    streaming       = false,
                    provider_status = res.status,
                    body_size       = body_str and #body_str or 0,
                    error_passthrough = true,
                })
                trace.done(ctx, "error", "provider_" .. res.status)
                return
            end

            -- Success path
            cb.record_success(ctx.gateway_id, provider_name, cb_cfg)

            -- TRACE: what the provider returned
            trace.step(ctx, "upstream_response", {
                attempt             = total_attempts,
                provider            = provider_name,
                model               = model,
                url                 = res.url,
                status              = res.status,
                latency_ms          = call_ms,
                provider_request_id = res.headers and
                    (res.headers["x-request-id"] or res.headers["request-id"]),
            })

            -- #7: for streaming, call_ms is TTFB; streaming handlers will overwrite
            -- upstream_latency_ms with total duration using upstream_t_start.
            ctx.upstream_latency_ms = call_ms
            ctx.upstream_ttfb_ms    = call_ms   -- #7: TTFB preserved separately
            ctx.upstream_t_start    = t_call    -- #7: used by streaming handlers
            ctx.upstream_attempts   = total_attempts
            ctx.provider_request_id = res.headers and
                (res.headers["x-request-id"] or res.headers["request-id"])
            if attempt_idx > 1 then
                ctx.fallback_provider = provider_name
                ctx.fallback_model    = model
            end
            -- Store rolling avg for cache savings estimates
            state.config_set("avg_upstream_ms:" .. provider_name .. ":" .. model,
                tostring(call_ms), 86400)

            -- Update ctx with the actual provider/model used
            ctx.provider = provider_name
            ctx.model    = model
            if not ngx.headers_sent then
                ngx.header["X-AIG-Provider"] = provider_name
                ngx.header["X-AIG-Model"]    = model
            end

            if is_streaming then
                if ctx.is_compat then
                    handle_compat_streaming(ctx, res)
                else
                    handle_streaming(ctx, res)
                end
                return  -- response already sent; skip rest of pipeline
            else
                local ok, parse_err = handle_buffered(ctx, res)
                if not ok then
                    last_err = parse_err
                    ngx.log(ngx.WARN, "upstream: parse error: ", parse_err)
                    goto next_try
                end

                -- Do NOT ngx.print here; send_response.lua runs after
                -- detectors_response so it can still block the response.
                ngx.status = res.status
                ngx.header["Content-Type"] = "application/json"
                ngx.header["X-AIG-Cache"]  = "MISS"
                return
            end

            ::next_try::
            -- backoff between retries (skip sleep after the last attempt)
            if try < retries then
                backoff_sleep(try, res and res.headers)
            end
        end

        ::continue::
    end

    -- All attempts exhausted
    ngx.log(ngx.ERR, "upstream: all providers failed. last_err=", last_err)
    trace.done(ctx, "error", last_err)
    errors.send("ALL_PROVIDERS_FAILED", last_err)
end

return M
