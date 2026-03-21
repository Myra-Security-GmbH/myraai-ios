-- detectors/keyword.lua — Tier 1 in-process keyword detector
-- Scans request or response body for exact keyword matches using plain string.find.
-- Does not support "scrub" action; treats it as "flagged".

local M = {}

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
    local keywords       = detector.keywords or {}

    if #keywords == 0 then
        return { verdict = "pass" }
    end

    -- Normalise the haystack once when case-insensitive
    local haystack = case_sensitive and text or text:lower()

    for _, kw in ipairs(keywords) do
        local needle = case_sensitive and kw or kw:lower()
        -- plain=true disables pattern magic in string.find
        if haystack:find(needle, 1, true) then
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
