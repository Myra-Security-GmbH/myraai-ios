-- core/gateway.lua — nginx phase hooks: access / content / log

local context  = require("core.context")
local pipeline = require("core.pipeline")

local M = {}

-- Middleware executed in the access phase (before reading body).
local ACCESS_PIPELINE = {
    "middleware.request_id",
    "middleware.tenant",
    "middleware.auth",
    "middleware.rate_limit",
    -- "middleware.quota",  -- disabled
    "middleware.ip_allowlist",
}

-- Middleware executed in the content phase (body available).
local CONTENT_PIPELINE = {
    "middleware.cache_check",
    "middleware.dlp",
    "middleware.guardrails_request",
    "middleware.transform",
    "middleware.routing",
    "middleware.byok",
    "middleware.upstream",
    "middleware.guardrails_response",
    "middleware.send_response",   -- prints buffered body after guardrails pass
    "middleware.cost",            -- compute cost before caching so entry includes cost_usd
    "middleware.cache_store",
}

-- Called from init_worker_by_lua_block — opens DB handles per worker.
function M.init_worker()
    require("core.config").init()
end

-- Called from access_by_lua_block
function M.access()
    context.init()
    pipeline.run(ACCESS_PIPELINE)
end

-- Called from content_by_lua_block
function M.content()
    pipeline.run(CONTENT_PIPELINE)
end

-- Called from log_by_lua_block (non-blocking, best-effort)
function M.log()
    local ok, err = pcall(function()
        require("middleware.log").run(ngx.ctx)
        require("observability.metrics").record(ngx.ctx)
    end)
    if not ok then
        ngx.log(ngx.ERR, "Log phase error: ", tostring(err))
    end
end

return M
