-- middleware/guardrails_response.lua — check the provider response for unsafe content
-- Skipped for streaming responses (already sent to client).

local errors = require("core.errors")

local M = {}

local PATTERNS = {
    self_harm = {
        "here('s| is) how to (commit suicide|self.harm)",
        "step.by.step.*?(suicide|self.harm)",
    },
    violence = {
        "here('s| is) how to (make|build) (a )?bomb",
        "detailed.*?instructions.*?(murder|assassination)",
    },
}

function M.run(ctx)
    -- Can't check streaming responses after they've been sent
    if ctx.is_streaming or not ctx.response_body then return end

    local gr = ctx.gateway_config.guardrails
    if not gr or not gr.enabled then return end

    local categories = gr.block_categories or {}
    if #categories == 0 then return end

    -- Extract text content from the response body
    local text = ctx.response_body:lower()

    for _, category in ipairs(categories) do
        local pats = PATTERNS[category]
        if pats then
            for _, pat in ipairs(pats) do
                if text:find(pat) then
                    ngx.log(ngx.WARN, "Guardrail response block: category=",
                            category, " tenant=", ctx.tenant_id)
                    -- For non-streaming, upstream.lua sets ctx.response_body but
                    -- does NOT print it. send_response.lua runs after this
                    -- middleware and checks ctx.guardrail_response_blocked first.
                    ctx.guardrail_response_blocked = category
                    return
                end
            end
        end
    end
end

return M
