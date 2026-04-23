-- guardrails/orchestrator.lua — shared orchestration logic for the guardrail pipeline
-- Runs Tier 1 guardrails (regex, keyword) before Tier 2 (presidio, prompt_guard).
-- Within the same tier, guardrails run in their original array order.

local M = {}

-- Classify a guardrail error message into a short, structured error_class
-- so operators can group outages (dns vs connect vs timeout vs http_5xx)
-- and the same string can be stored in request_log.meta for querying.
local function classify_error(msg)
    if not msg then return "unknown" end
    local s = tostring(msg):lower()
    if s:find("could not be resolved", 1, true)
       or s:find("no such host", 1, true)
       or s:find("name resolution", 1, true) then
        return "dns"
    end
    if s:find("connection refused", 1, true) then return "connect_refused" end
    if s:find("timeout", 1, true) or s:find("timed out", 1, true) then return "timeout" end
    if s:find("broken pipe", 1, true) or s:find("closed", 1, true) then return "connection_closed" end
    local code = s:match("http%s+(%d%d%d)")
    if code then return "http_" .. code end
    if s:find("parse", 1, true) then return "parse" end
    return "transport"
end

-- Record a guardrail outage on ctx so it flows to log lines, request_log.meta,
-- and the X-Aig-Guardrail-Warning response header.
local function record_guardrail_error(ctx, det, result)
    local err_class = classify_error(result.message)
    local name      = det.name or det.type
    local info = {
        name        = name,
        type        = det.type,
        stage       = result.stage,
        url         = result.url,
        error_class = err_class,
        message     = tostring(result.message or ""),
    }

    ctx.log_fields.guardrail_error   = info
    ctx.log_fields.guardrail_verdict = "error"
    ctx.meta = ctx.meta or {}
    ctx.meta.guardrail_error = info

    -- Structured single-line ERR log so operators see outages immediately.
    ngx.log(ngx.ERR,
        "[guardrail_unavailable]",
        " name=", name,
        " type=", tostring(det.type),
        " stage=", tostring(result.stage or "?"),
        " error_class=", err_class,
        " url=", tostring(result.url or "?"),
        " tenant=", tostring(ctx.tenant_id or "?"),
        " gateway=", tostring(ctx.gateway_id or "?"),
        " fail_open=", tostring(det.fail_open ~= false),
        " message=", tostring(result.message or ""))

    return err_class
end

-- Tier assignment: lower number runs first.
local TIER = {
    regex         = 1,
    keyword       = 1,
    jailbreak     = 1,
    json_schema   = 1,
    contains_code = 1,
    gibberish     = 1,
    language      = 1,
    custom_pii    = 1,   -- Tier 1: pure Lua, no sidecar (AGF-2)
    presidio      = 2,
    prompt_guard  = 2,
    pii_protector = 2,
}

local MODULES = {
    regex         = "guardrails.regex",
    keyword       = "guardrails.keyword",
    jailbreak     = "guardrails.jailbreak",
    json_schema   = "guardrails.json_schema",
    contains_code = "guardrails.contains_code",
    gibberish     = "guardrails.gibberish",
    language      = "guardrails.language",
    custom_pii    = "guardrails.custom_pii",
    presidio      = "guardrails.presidio",
    prompt_guard  = "guardrails.prompt_guard",
    pii_protector = "guardrails.pii_protector",
}

-- Run all guardrails applicable to `phase` ("request" or "response").
-- Returns "block" if any guardrail blocks, otherwise "pass".
-- Reads from ctx.gateway_config.guardrails; falls back to .detectors for
-- backward compatibility with configs saved before the rename.
function M.run_phase(ctx, phase)
    local detectors_cfg = ctx.gateway_config and
        (ctx.gateway_config.guardrails or ctx.gateway_config.detectors)
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
            ngx.log(ngx.ERR, "guardrails: unknown guardrail type '", tostring(det.type),
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
                -- pcall failure: synthesise an error verdict so the outage
                -- travels the same code path as explicit errors.
                result = { verdict = "error", stage = "pcall",
                           message = tostring(result) }
            end

            local verdict = result and result.verdict or "pass"

            if verdict == "error" then
                record_guardrail_error(ctx, det, result)
                if det.fail_open == false then
                    ctx.log_fields.blocked_by   = det.name or det.type
                    ctx.log_fields.block_reason = "guardrail_unavailable:" ..
                                                   (det.name or det.type)
                    return "block"
                end
                -- fail_open (default): mark degraded and continue
                ctx.log_fields.guardrail_degraded = true
                ctx.meta = ctx.meta or {}
                ctx.meta.guardrail_degraded = true

            elseif verdict == "block" then
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
                ctx.log_fields.block_reason = result and result.pattern
                -- For request phase, propagate the scrubbed body to nginx
                if phase == "request" then
                    ngx.req.set_body_data(ctx.raw_request_body)
                end
                -- Continue to remaining detectors

            elseif verdict == "flagged" then
                local fired = ctx.log_fields.detectors_fired
                fired[#fired + 1] = det.name or det.type
                ctx.log_fields.block_reason = result and result.pattern
                -- Continue to remaining detectors

            -- else "pass": continue silently
            end
        end
    end

    return "pass"
end

return M
