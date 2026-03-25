-- middleware/request_id.lua — inject a unique request ID into context and headers
local uuid = require("utils.uuid")

local M = {}

function M.run(ctx)
    local id = ngx.var.http_x_request_id
    if not id or id == "" then
        id = uuid.v4()
    end
    ctx.request_id = id
    ngx.req.set_header("X-Request-Id", id)
    ngx.header["X-Request-Id"] = id
    -- Initialise OTel trace context if tracing is configured for this gateway
    local tracing = ctx.gateway_config and ctx.gateway_config.tracing
    if tracing and (tracing.enabled or tracing.otlp_endpoint) then
        pcall(function() require("observability.tracer").init(ctx) end)
    end
end

return M
