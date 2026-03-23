-- guardrails/language.lua — Tier 1 script-mode writing-system detector
-- Detects the dominant writing system of text content using UTF-8 byte
-- range heuristics. Pure Lua, zero external dependencies (~0ms overhead).
--
-- Limitation: cannot distinguish within the Latin script (English, French,
-- Spanish, etc. all map to "latin"). Use a sidecar language-detect service
-- for sub-Latin discrimination.
--
-- Detected codes:
--   latin      — ASCII + Latin-range text (default when no other script dominates)
--   cjk        — Chinese / Japanese / Korean (U+4E00–U+9FFF)
--   cyrillic   — Russian, Bulgarian, Serbian, … (U+0400–U+04FF)
--   arabic     — Arabic, Farsi, Urdu (U+0600–U+06FF)
--   hebrew     — Hebrew (U+0590–U+05FF, partial)
--   thai       — Thai (U+0E00–U+0E7F)
--   devanagari — Hindi, Sanskrit, … (U+0900–U+097F)
--
-- Config fields:
--   allowed    []string  — language codes permitted; anything else → action
--   action     string    — "block" | "flag" (default "block")
--   min_ratio  number    — min fraction of total chars that must be classified
--                          as non-Latin to override the "latin" default (default 0.1)

local M = {}

-- Count occurrences of each non-Latin writing system by inspecting leading
-- bytes of UTF-8 multi-byte sequences.  Returns a table {lang → count} and
-- the total character (code-point) count.
local function count_scripts(text)
    local counts = { cjk=0, cyrillic=0, arabic=0, hebrew=0, thai=0, devanagari=0 }
    local total  = 0
    local n = #text
    local i = 1
    while i <= n do
        local b = text:byte(i)
        total = total + 1
        if b < 0x80 then
            -- ASCII — Latin
            i = i + 1
        elseif b >= 0xE4 and b <= 0xE9 then
            -- 3-byte sequence: likely CJK U+4E00–U+9FFF
            counts.cjk = counts.cjk + 1
            i = i + 3
        elseif b == 0xE0 then
            -- 3-byte starting 0xE0: Thai or Devanagari depending on second byte
            local b2 = i < n and text:byte(i + 1) or 0
            if b2 >= 0xA4 and b2 <= 0xA5 then
                counts.devanagari = counts.devanagari + 1
            elseif b2 >= 0xB8 and b2 <= 0xB9 then
                counts.thai = counts.thai + 1
            end
            i = i + 3
        elseif b >= 0xD0 and b <= 0xD3 then
            -- 2-byte: Cyrillic U+0400–U+04FF
            counts.cyrillic = counts.cyrillic + 1
            i = i + 2
        elseif b >= 0xD6 and b <= 0xD7 then
            -- 2-byte: Hebrew U+0590–U+05FF (leading bytes D6–D7)
            counts.hebrew = counts.hebrew + 1
            i = i + 2
        elseif b >= 0xD8 and b <= 0xDB then
            -- 2-byte: Arabic U+0600–U+06FF
            counts.arabic = counts.arabic + 1
            i = i + 2
        elseif b >= 0xF0 then
            i = i + 4   -- 4-byte sequence (e.g. emoji)
        elseif b >= 0xE0 then
            i = i + 3   -- other 3-byte
        elseif b >= 0xC0 then
            i = i + 2   -- other 2-byte
        else
            i = i + 1   -- continuation byte — skip
        end
    end
    return counts, total
end

local function get_body(ctx, phase)
    return phase == "response" and ctx.response_body or ctx.raw_request_body
end

function M.run(ctx, detector, phase)
    local body = get_body(ctx, phase)
    if not body or body == "" then return { verdict = "pass" } end

    local allowed   = detector.allowed
    local action    = detector.action   or "block"
    local min_ratio = detector.min_ratio or 0.1

    -- Without an allowlist there is nothing to enforce
    if not allowed or #allowed == 0 then return { verdict = "pass" } end

    local counts, total = count_scripts(body)

    -- Find the dominant non-Latin script (if any)
    local dominant_lang, dominant_count = nil, 0
    for lang, count in pairs(counts) do
        if count > dominant_count then
            dominant_count = count
            dominant_lang  = lang
        end
    end

    local detected
    if dominant_lang and total > 0 and (dominant_count / total) >= min_ratio then
        detected = dominant_lang
    else
        detected = "latin"
    end

    -- Build allowed set for O(1) lookup
    local allowed_set = {}
    for _, lang in ipairs(allowed) do allowed_set[lang] = true end

    if allowed_set[detected] then return { verdict = "pass" } end

    local reason = "language:" .. detected
    if action == "block" then
        return { verdict = "block", pattern = reason }
    else
        return { verdict = "flagged", pattern = reason }
    end
end

return M
