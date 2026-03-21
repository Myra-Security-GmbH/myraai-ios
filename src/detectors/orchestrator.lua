-- detectors/orchestrator.lua — shared orchestration logic for the detector pipeline
-- Runs Tier 1 detectors (regex, keyword) before Tier 2 (presidio, llm_guard).
-- Within the same tier, detectors run in their original array order.

local M = {}

-- Tier assignment: lower number runs first.
local TIER = {
    regex         = 1,
    keyword       = 1,
    presidio      = 2,
    llm_guard     = 2,
    pii_protector = 2,
}

local MODULES = {
    regex         = "detectors.regex",
    keyword       = "detectors.keyword",
    presidio      = "detectors.presidio",
    llm_guard     = "detectors.llm_guard",
    pii_protector = "detectors.pii_protector",
}

-- Run all detectors applicable to `phase` ("request" or "response").
-- Returns "block" if any detector blocks, otherwise "pass".
function M.run_phase(ctx, phase)
    local detectors_cfg = ctx.gateway_config and ctx.gateway_config.detectors
    if not detectors_cfg or #detectors_cfg == 0 then
        return "pass"
    end

    ctx.log_fields = ctx.log_fields or {}
    ctx.log_fields.detectors_fired = ctx.log_fields.detectors_fired or {}

    -- Collect detectors applicable to this phase.
    -- Default target is "request" when not specified.
    local applicable = {}
    for i, det in ipairs(detectors_cfg) do
        local target = det.target or "request"
        if target == phase or target == "both" then
            applicable[#applicable + 1] = { index = i, det = det }
        end
    end

    if #applicable == 0 then
        return "pass"
    end

    -- Stable sort by tier (preserve original array order within the same tier).
    table.sort(applicable, function(a, b)
        local ta = TIER[a.det.type] or 99
        local tb = TIER[b.det.type] or 99
        if ta ~= tb then return ta < tb end
        return a.index < b.index
    end)

    -- Execute each detector.
    for _, entry in ipairs(applicable) do
        local det = entry.det
        local mod_name = MODULES[det.type]

        if not mod_name then
            ngx.log(ngx.WARN, "detectors: unknown detector type '", tostring(det.type),
                    "' name=", tostring(det.name))
            -- Unknown type: respect fail_open
            if det.fail_open == false then
                ctx.log_fields.blocked_by   = det.name or det.type
                ctx.log_fields.block_reason = "unknown_detector_type"
                return "block"
            end
        else
            local ok, result = pcall(function()
                return require(mod_name).run(ctx, det, phase)
            end)

            if not ok then
                -- result holds the error message on pcall failure
                ngx.log(ngx.WARN, "detectors: error running detector '",
                        tostring(det.name or det.type), "': ", tostring(result))
                if det.fail_open == false then
                    ctx.log_fields.blocked_by   = det.name or det.type
                    ctx.log_fields.block_reason = "detector_error"
                    return "block"
                end
                -- fail_open (default): continue to next detector
            else
                local verdict = result and result.verdict or "pass"

                if verdict == "block" then
                    ctx.log_fields.blocked_by      = det.name or det.type
                    ctx.log_fields.block_reason    = result.pattern
                    if result.entities then
                        ctx.log_fields.block_entities = result.entities
                    end
                    local fired = ctx.log_fields.detectors_fired
                    fired[#fired + 1] = det.name or det.type
                    return "block"

                elseif verdict == "scrubbed" then
                    ctx.log_fields.scrub_applied = true
                    if result.entities then
                        ctx.log_fields.scrub_entities = result.entities
                    end
                    local fired = ctx.log_fields.detectors_fired
                    fired[#fired + 1] = det.name or det.type
                    -- For request phase, propagate the scrubbed body to nginx
                    if phase == "request" then
                        ngx.req.set_body_data(ctx.raw_request_body)
                    end
                    -- Continue to remaining detectors

                elseif verdict == "flagged" then
                    local fired = ctx.log_fields.detectors_fired
                    fired[#fired + 1] = det.name or det.type
                    -- Continue to remaining detectors

                -- else "pass": continue silently
                end
            end
        end
    end

    return "pass"
end

return M
