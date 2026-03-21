-- guardrails/keyword.lua — Tier 1 in-process keyword guardrail
-- Scans request or response body for exact keyword matches using plain string.find.
-- Does not support "scrub" action; treats it as "flagged".
-- Supports whole_word:true to avoid substring false positives (e.g. "kill" in "skill").

local M = {}

-- Escape Lua pattern magic characters so a keyword can be embedded in a pattern.
local function escape_pattern(s)
    return (s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1"))
end

-- Determine which body text to scan based on phase.
local function get_body(ctx, phase)
    if phase == "response" then
        return ctx.response_body
    else
        return ctx.raw_request_body
    end
end

function M.run(ctx, detector, phase)
    local text = get_body(ctx, phase)
    if not text or text == "" then
        return { verdict = "pass" }
    end

    local action         = detector.action or "flag"
    local case_sensitive = detector.case_sensitive  -- nil → false
    local whole_word     = detector.whole_word       -- nil → false
    local keywords       = detector.keywords or {}

    if #keywords == 0 then
        return { verdict = "pass" }
    end

    -- Normalise the haystack once when case-insensitive
    local haystack = case_sensitive and text or text:lower()

    for _, kw in ipairs(keywords) do
        local needle  = case_sensitive and kw or kw:lower()
        local matched

        if whole_word then
            -- Use frontier patterns to require word boundaries so that e.g.
            -- "kill" does not fire on "skill" or "toolkit".
            -- %f[%w] = transition into a word char; %f[%W] = transition out.
            local pat = "%f[%w]" .. escape_pattern(needle) .. "%f[%W]"
            matched = haystack:find(pat) ~= nil
        else
            -- plain=true disables pattern magic in string.find
            matched = haystack:find(needle, 1, true) ~= nil
        end

        if matched then
            if action == "block" then
                return { verdict = "block", pattern = kw }
            else
                -- "scrub" is not supported; treat as "flagged"
                return { verdict = "flagged", pattern = kw }
            end
        end
    end

    return { verdict = "pass" }
end

return M
