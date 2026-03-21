-- middleware/guardrails_response.lua — Response-phase guardrail middleware entry point.
-- Runs after the upstream response is received and buffered.
-- Skips streaming responses (body not available as a single buffer).
-- On block: sets ctx.guardrail_response_blocked so downstream middleware can handle it.

local M = {}

function M.run(ctx)
    if ctx.is_streaming or not ctx.response_body then return end
    local result = require("guardrails.orchestrator").run_phase(ctx, "response")
    if result == "block" then
        ctx.guardrail_response_blocked = ctx.log_fields.blocked_by or "guardrail"
    end
end

return M
