-- guardrails/regex.lua — Tier 1 in-process regex guardrail
-- Scans request or response body text against a set of named/custom patterns.
-- Supports block, scrub, and flag actions.

local patterns_lib = require("guardrails.patterns")

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

    -- Returns true if the match should be accepted after any checksum validation.
    local function checksum_ok(name, match)
        if name == "cc"             then return patterns_lib.luhn_check(match) end
        if name == "routing_number" then return patterns_lib.aba_check(match)  end
        return true
    end

    if action == "scrub" then
        -- Scan all patterns and scrub all matches; report first match found.
        local first_match
        local scrubbed = text
        local any_scrubbed = false

        for _, p in ipairs(all_patterns) do
            local pat  = p.pattern
            local name = p.name

            if name == "cc" or name == "routing_number" then
                local ok_gsub, new_text = pcall(function()
                    return scrubbed:gsub(pat, function(match)
                        if checksum_ok(name, match) then
                            if not first_match then first_match = name end
                            any_scrubbed = true
                            return placeholder
                        end
                        return match
                    end)
                end)
                if ok_gsub then
                    scrubbed = new_text
                else
                    ngx.log(ngx.WARN, "regex guardrail: invalid pattern name=", name,
                            " pattern=", tostring(pat))
                end
            else
                local ok_gsub, new_text, count = pcall(string.gsub, scrubbed, pat, placeholder)
                if ok_gsub then
                    if count and count > 0 then
                        if not first_match then first_match = name end
                        any_scrubbed = true
                        scrubbed = new_text
                    end
                else
                    ngx.log(ngx.WARN, "regex guardrail: invalid pattern name=", name,
                            " pattern=", tostring(pat))
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

            if name == "cc" or name == "routing_number" then
                local ok_match, found = pcall(string.match, text, pat)
                if not ok_match then
                    ngx.log(ngx.WARN, "regex guardrail: invalid pattern name=", name,
                            " pattern=", tostring(pat))
                elseif found and checksum_ok(name, found) then
                    if action == "block" then
                        return { verdict = "block", pattern = name }
                    else
                        return { verdict = "flagged", pattern = name }
                    end
                end
            else
                local ok_match, matched = pcall(string.match, text, pat)
                if not ok_match then
                    ngx.log(ngx.WARN, "regex guardrail: invalid pattern name=", name,
                            " pattern=", tostring(pat))
                elseif matched then
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
