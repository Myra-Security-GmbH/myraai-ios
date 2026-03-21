-- middleware/transform.lua — parse and normalise the request body
-- Ensures ctx.request_body is an OpenAI-format Lua table.
-- Also resolves provider and model for compat requests.

local json        = require("utils.json")
local compat      = require("providers.compat")
local errors      = require("core.errors")
local req_util    = require("utils.request")

local M = {}

function M.run(ctx)
    -- Body may have already been read by cache_check or DLP
    if not ctx.raw_request_body then
        ctx.raw_request_body = req_util.read_body()
    end

    local raw = ctx.raw_request_body
    if not raw or raw == "" then
        errors.send("INVALID_REQUEST", "Empty request body")
        return
    end

    if not ctx.request_body then
        ctx.request_body = json.decode(raw)
        if not ctx.request_body then
            errors.send("INVALID_REQUEST", "Invalid JSON body")
            return
        end
    end

    local body = ctx.request_body

    -- Resolve model
    ctx.model = body.model
    if not ctx.model then
        errors.send("INVALID_REQUEST", "Missing 'model' field")
        return
    end

    -- For compat endpoint: infer the real provider from the model name.
    -- infer_provider() always returns a provider string (falls back to openrouter).
    if ctx.is_compat then
        ctx.provider      = compat.infer_provider(ctx.model)
        ctx.provider_path = compat.provider_path(ctx.provider_path)
    end

    -- Collect custom metadata from x-aig-meta-* headers
    local req_headers = ngx.req.get_headers()
    for k, v in pairs(req_headers) do
        local meta_key = k:match("^x%-aig%-meta%-(.+)$")
        if meta_key then
            ctx.meta[meta_key] = v
        end
    end

    -- Honour x-aig-collect-log override
    local collect = req_headers["x-aig-collect-log"]
    if collect == "false" or collect == "0" then
        ctx.skip_log = true
    end
    local collect_payload = req_headers["x-aig-collect-log-payload"]
    if collect_payload == "false" or collect_payload == "0" then
        ctx.skip_log_payload = true
    end
end

return M
