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
        input_tokens  = ctx.input_tokens  or 0,
        output_tokens = ctx.output_tokens or 0,
        cost_usd      = ctx.cost_usd      or 0,
        latency_ms    = ctx.start_ms
                        and math.floor(ngx.now() * 1000 - ctx.start_ms)
                        or  0,
        ts            = os.date("!%Y-%m-%dT%H:%M:%S") ..
                        string.format(".%03dZ", (ngx.now() * 1000) % 1000),
        prompt        = prompt,
        response      = response,
        meta          = ctx.meta or {},
    }

    -- Merge any extra log fields added by other middleware (e.g. blocked_by, block_reason)
    for k, v in pairs(ctx.log_fields or {}) do
        fields[k] = v
    end

    -- Derive blocked flag from blocked_by (set by guardrails/dlp/rate_limit/etc.)
    fields.blocked = fields.blocked_by ~= nil

    local err = storage.insert_log(fields)
    if err then
        ngx.log(ngx.ERR, "logger: insert_log error: ", err)
    end
end

return M
