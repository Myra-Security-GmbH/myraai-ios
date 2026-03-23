-- guardrails/jailbreak.lua — Tier 1 in-process jailbreak / prompt-injection guardrail
-- Ships with 18 built-in attack phrases that cover the most common literal jailbreak
-- patterns (DAN, instruction-override, bypass, etc.).
--
-- Behaviour:
--   detector.keywords nil or empty → built-in phrase list is used
--   detector.keywords non-empty    → supplied list replaces built-ins entirely
--
-- Does not support "scrub" action; treats it as "flagged".
-- Whole-word matching is off by default so inflected forms are also caught
-- (e.g. "bypassing your restrictions" matches "bypass your restrictions").

local M = {}

local BUILT_IN_KEYWORDS = {
    "ignore previous instructions",
    "ignore all instructions",
    "ignore your instructions",
    "disregard previous instructions",
    "disregard your instructions",
    "forget your instructions",
    "DAN mode",
    "do anything now",
    "jailbreak",
    "developer mode",
    "unrestricted mode",
    "your true self",
    "bypass your guidelines",
    "bypass your restrictions",
    "override your guidelines",
    "override your restrictions",
    "prompt injection",
    "[SYSTEM]",
}

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

    -- Override semantics: use custom list when non-empty, else built-ins.
    local custom = detector.keywords
    local keywords
    if custom and #custom > 0 then
        keywords = custom
    else
        keywords = BUILT_IN_KEYWORDS
    end

    -- Normalise the haystack once when case-insensitive.
    local haystack = case_sensitive and text or text:lower()

    for _, kw in ipairs(keywords) do
        local needle  = case_sensitive and kw or kw:lower()
        local matched

        if whole_word then
            local pat = "%f[%w]" .. escape_pattern(needle) .. "%f[%W]"
            matched = haystack:find(pat) ~= nil
        else
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
