-- observability/logger.lua — structured JSON request log emitter
-- Dev/test: writes to storage (logs.db via SQLite).
-- Production: swap for UDP → Vector/Loki or HTTP → ClickHouse.

local storage = require("storage")
local json    = require("utils.json")
local uuid    = require("utils.uuid")

local M = {}

function M.emit(ctx)
    if ctx.skip_log then return end

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
    }

    -- Merge any extra log fields added by other middleware (e.g. blocked_by, block_reason)
    for k, v in pairs(ctx.log_fields or {}) do
        fields[k] = v
    end

    -- Derive blocked flag from blocked_by (set by guardrails/detector/rate_limit/etc.)
    fields.blocked = fields.blocked_by ~= nil

    local err = storage.insert_log(fields)
    if err then
        ngx.log(ngx.ERR, "logger: insert_log error: ", err)
    end

    -- Fire "blocked" webhook asynchronously when the request was blocked
    if fields.blocked and ctx.gateway_config and ctx.gateway_config.webhooks then
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
end

return M
