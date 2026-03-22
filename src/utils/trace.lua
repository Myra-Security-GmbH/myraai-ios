-- utils/trace.lua — request trace recorder (playground + gateway tracing).
-- All writes are pcall'd — tracing never breaks request flow.

local json = require("utils.json")

local M = {}

-- Create a new trace record. ctx.trace_id and ctx.gateway_id must be set.
-- source: 'playground' | 'gateway'
function M.create(ctx, source)
    if not ctx or not ctx.trace_id then return end
    pcall(function()
        require("storage").create_trace(
            ctx.trace_id, ctx.gateway_id,
            ctx.request_body and ctx.request_body.model or nil,
            source or "gateway"
        )
    end)
end

-- Append one trace step. ctx.trace_id must be set.
function M.step(ctx, step, data)
    if not ctx or not ctx.trace_id then return end
    local ok, err = pcall(function()
        local storage = require("storage")
        ctx.trace_seq = (ctx.trace_seq or 0) + 1
        storage.add_playground_trace_step(
            ctx.trace_id, ctx.trace_seq, step,
            json.encode(data or {})
        )
    end)
    if not ok then
        ngx.log(ngx.WARN, "trace.step error: ", tostring(err))
    end
end

-- Mark the trace complete.
function M.done(ctx, status, error_msg)
    if not ctx or not ctx.trace_id then return end
    pcall(function()
        require("storage").complete_playground_trace(ctx.trace_id, status or "done", error_msg)
    end)
end

return M
