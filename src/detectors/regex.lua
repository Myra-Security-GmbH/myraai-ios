-- detectors/regex.lua — Tier 1 in-process regex detector
-- Scans request or response body text against a set of named/custom patterns.
-- Supports block, scrub, and flag actions.

local patterns_lib = require("detectors.patterns")

local M = {}

local DEFAULT_PLACEHOLDER = "[REDACTED]"

-- Determine which body text to scan based on phase.
local function get_body(ctx, phase)
    if phase == "response" then
        return ctx.response_body
    else
        return ctx.raw_request_body
    end
end

-- Update the body in ctx based on phase.
local function set_body(ctx, phase, text)
    if phase == "response" then
        ctx.response_body = text
    else
        ctx.raw_request_body = text
    end
end

function M.run(ctx, detector, phase)
    local text = get_body(ctx, phase)
    if not text or text == "" then
        return { verdict = "pass" }
    end

    local action      = detector.action or "flag"
    local placeholder = detector.scrub_placeholder or DEFAULT_PLACEHOLDER

    -- Build list of patterns to scan: named/set patterns + custom raw patterns
    local named_patterns = patterns_lib.resolve(detector.patterns or {})
    local all_patterns   = {}
    for _, p in ipairs(named_patterns) do
        all_patterns[#all_patterns + 1] = p
    end
    for _, raw_pat in ipairs(detector.custom_patterns or {}) do
        all_patterns[#all_patterns + 1] = { name = "custom:" .. raw_pat, pattern = raw_pat }
    end

    if #all_patterns == 0 then
        return { verdict = "pass" }
    end

    if action == "scrub" then
        -- Scan all patterns and scrub all matches; report first match found.
        local first_match
        local scrubbed = text
        local any_scrubbed = false

        for _, p in ipairs(all_patterns) do
            local pat  = p.pattern
            local name = p.name

            -- For cc patterns apply Luhn check to avoid false positives
            if name == "cc" then
                local new_text = scrubbed:gsub(pat, function(match)
                    if patterns_lib.luhn_check(match) then
                        if not first_match then first_match = name end
                        any_scrubbed = true
                        return placeholder
                    end
                    return match
                end)
                scrubbed = new_text
            else
                local new_text, count = scrubbed:gsub(pat, placeholder)
                if count and count > 0 then
                    if not first_match then first_match = name end
                    any_scrubbed = true
                    scrubbed = new_text
                end
            end
        end

        if any_scrubbed then
            set_body(ctx, phase, scrubbed)
            return { verdict = "scrubbed", pattern = first_match }
        end
        return { verdict = "pass" }
    else
        -- block or flag: find the first match and return immediately
        for _, p in ipairs(all_patterns) do
            local pat  = p.pattern
            local name = p.name

            if name == "cc" then
                -- Need to find a match and do Luhn check
                local found = text:match(pat)
                if found and patterns_lib.luhn_check(found) then
                    if action == "block" then
                        return { verdict = "block", pattern = name }
                    else
                        return { verdict = "flagged", pattern = name }
                    end
                end
            else
                if text:match(pat) then
                    if action == "block" then
                        return { verdict = "block", pattern = name }
                    else
                        return { verdict = "flagged", pattern = name }
                    end
                end
            end
        end

        return { verdict = "pass" }
    end
end

return M
