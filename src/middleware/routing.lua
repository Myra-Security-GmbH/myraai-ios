-- middleware/routing.lua — select provider + model via routing rules
-- Sets ctx.provider, ctx.model, ctx.fallback_chain.

local engine = require("routing.engine")
local trace  = require("utils.trace")

local M = {}

function M.run(ctx)
    local actions = engine.evaluate(ctx)

    if actions then
        local prev_provider = ctx.provider
        local prev_model    = ctx.model

        -- A routing rule matched
        if actions.provider then ctx.provider = actions.provider end
        if actions.model    then
            ctx.model = actions.model
            ctx.request_body.model = actions.model
        end
        -- Build fallback chain: [{provider, model}, ...]
        ctx.fallback_chain = actions.fallbacks or {}
        -- Per-rule timeout override
        if actions.timeout_ms then ctx.rule_timeout_ms = tonumber(actions.timeout_ms) end

        -- TRACE: routing decision
        trace.step(ctx, "routing_applied", {
            provider_before = prev_provider,
            model_before    = prev_model,
            provider_after  = ctx.provider,
            model_after     = ctx.model,
            fallbacks_count = #ctx.fallback_chain,
            timeout_ms      = ctx.rule_timeout_ms,
        })
    else
        -- No rule matched — use whatever was in the request as-is
        ctx.fallback_chain = {}
    end
end

return M
