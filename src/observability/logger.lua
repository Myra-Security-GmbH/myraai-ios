-- observability/logger.lua — structured JSON request log emitter
-- Dev/test: writes to storage (logs.db via SQLite).
-- Production: swap for UDP → Vector/Loki or HTTP → ClickHouse.

local storage = require("storage")
local json    = require("utils.json")
local uuid    = require("utils.uuid")

local M = {}

function M.emit(ctx)
    if ctx.skip_log then return end
    if not ctx.gateway_config then return end  -- OPTIONS / pre-auth requests have no gateway context

    local prompt, response
    if ctx.gateway_config.log_payloads and not ctx.skip_log_payload then
        -- Extract human-readable prompt text from the request body
        if ctx.request_body then
            if ctx.request_body.messages then
                local parts = {}
                for _, msg in ipairs(ctx.request_body.messages) do
                    local content = type(msg.content) == "string"
                        and msg.content
                        or json.encode(msg.content)
                    parts[#parts + 1] = (msg.role or "?") .. ": " .. (content or "")
                end
                prompt = table.concat(parts, "\n")
            elseif ctx.request_body.prompt then
                prompt = ctx.request_body.prompt
            end
        end

        response = ctx.response_body  -- nil for streaming
    end

    local fields = {
        id            = ctx.request_id or uuid.v4(),
        tenant_id     = ctx.tenant_id  or "",
        gateway_id    = ctx.gateway_id or "",
        provider      = ctx.provider   or "",
        model         = ctx.model      or "",
        status        = ctx.provider_status or ngx.status,
        cached        = ctx.cache_hit  or false,
        input_tokens          = ctx.input_tokens          or 0,
        output_tokens         = ctx.output_tokens         or 0,
        cache_creation_tokens = ctx.cache_creation_tokens or 0,
        cache_read_tokens     = ctx.cache_read_tokens     or 0,
        cost_usd              = ctx.cost_usd              or 0,
        latency_ms    = ctx.start_ms
                        and math.floor(ngx.now() * 1000 - ctx.start_ms)
                        or  0,
        ts            = math.floor(ngx.now() * 1000),
        prompt        = prompt,
        response      = response,
        meta          = ctx.meta or {},
        -- Upstream provider metrics
        upstream_latency_ms    = ctx.upstream_latency_ms,
        time_to_first_token_ms = ctx.time_to_first_token_ms,
        upstream_attempts      = ctx.upstream_attempts,
        fallback_provider      = ctx.fallback_provider,
        fallback_model         = ctx.fallback_model,
        provider_request_id    = ctx.provider_request_id,
        -- Request metadata
        request_size_bytes     = ctx.raw_request_body and #ctx.raw_request_body or 0,
        -- User attribution
        user_id                = ctx.user_id,
        token_label            = ctx.token_label,
        -- Detector pipeline
        detectors_fired        = ctx.log_fields and ctx.log_fields.detectors_fired or {},
        scrub_applied          = ctx.log_fields and ctx.log_fields.scrub_applied or false,
        -- Request trace link
        trace_id               = ctx.trace_id,
    }

    -- Merge any extra log fields added by other middleware (e.g. blocked_by, block_reason)
    for k, v in pairs(ctx.log_fields or {}) do
        fields[k] = v
    end

    -- Derive blocked flag from blocked_by (set by guardrails/detector/rate_limit/etc.)
    fields.blocked = fields.blocked_by ~= nil

    -- Defer the DB write via timer so it runs outside log_by_lua* context,
    -- which is required for resty.mysql (MySQL API is disabled in log phase).
    ngx.timer.at(0, function(_, f)
        local s = require("storage")
        local e = s.insert_log(f)
        if e then ngx.log(ngx.ERR, "logger: insert_log error: ", e) end
    end, fields)

    -- Finalise trace for blocked/error paths that did not reach send_response.lua
    -- or the streaming handlers (idempotent — already called for normal completions).
    -- Must be deferred: MySQL API is disabled in log_by_lua* phase.
    if ctx.trace_id then
        local trace_status = fields.blocked and "blocked" or "done"
        local trace_err    = fields.blocked and fields.block_reason or nil
        ngx.timer.at(0, function(_, tid, st, er)
            require("storage").complete_playground_trace(tid, st, er)
        end, ctx.trace_id, trace_status, trace_err)
    end

    -- Fire "blocked" webhook asynchronously when the request was blocked
    if fields.blocked and ctx.gateway_config and type(ctx.gateway_config.webhooks) == "table" then
        local ok, wh = pcall(require, "utils.webhook")
        if ok then
            wh.fire(ctx.gateway_config.webhooks, "blocked", {
                blocked_by   = fields.blocked_by,
                block_reason = fields.block_reason,
                provider     = fields.provider,
                model        = fields.model,
                request_id   = fields.id,
            }, { gateway_id = ctx.gateway_id, tenant_id = ctx.tenant_id })
        end
    end

    -- Stream to SIEM (gateway.config.siem overrides tenant-level siem, already merged)
    local siem_cfg = ctx.gateway_config and ctx.gateway_config.siem
    if type(siem_cfg) == "table" then
        local ok, siem = pcall(require, "observability.siem")
        if ok then siem.emit(siem_cfg, fields) end
    end

    -- Fire OTel span export asynchronously
    local tracing = ctx.gateway_config and ctx.gateway_config.tracing
    if type(tracing) == "table" and tracing.otlp_endpoint then
        local ok, tracer = pcall(require, "observability.tracer")
        if ok then tracer.emit(ctx, tracing) end
    end
end

return M
