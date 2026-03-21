-- middleware/send_response.lua — send the buffered non-streaming response
-- Runs after detectors_response so a blocked response is never sent.
-- Streaming responses are already sent by upstream.lua; this is a no-op for them.

local errors = require("core.errors")

local M = {}

function M.run(ctx)
    if ctx.is_streaming then return end  -- already sent

    -- If guardrails flagged the response, block it now before sending
    if ctx.guardrail_response_blocked then
        errors.send("GUARDRAIL_BLOCKED",
            "Response blocked by content policy: " .. ctx.guardrail_response_blocked)
    end

    if not ctx.response_body then return end

    ngx.print(ctx.response_body)
end

return M
