-- utils/trace.lua — fire-and-forget server-side playground query tracer.
-- All writes are pcall'd — tracing never breaks request flow.

local json = require("utils.json")

local M = {}

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
