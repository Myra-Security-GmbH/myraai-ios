-- guardrails/gibberish.lua — Tier 1 response-phase gibberish detector
-- Uses three independent heuristic signals to score text quality.
-- Designed for response phase only; request phase is always passed.
--
-- Signals:
--   1. Shannon character entropy  H < entropy_threshold (default 2.5) → repetitive
--   2. Word repetition ratio      unique/total < word_repeat_ratio (default 0.15)
--   3. Alpha character ratio      alpha/total < alpha_ratio (default 0.6)
--
-- Thresholds: 1 signal → "flagged" always; ≥2 signals → apply action (block/flag)
-- Guards: skips text shorter than 20 chars; skips alpha-ratio check for non-Latin text.
--
-- Config fields:
--   action              "block" | "flag" (default "block")
--   entropy_threshold   number  (default 2.5)
--   word_repeat_ratio   number  (default 0.15)
--   alpha_ratio         number  (default 0.6)

local cjson = require("cjson.safe")

local M = {}

local function shannon_entropy(text)
    local freq = {}
    local n = #text
    if n == 0 then return 0 end
    for i = 1, n do
        local c = text:sub(i, i)
        freq[c] = (freq[c] or 0) + 1
    end
    local h = 0
    for _, count in pairs(freq) do
        local p = count / n
        h = h - p * (math.log(p) / math.log(2))
    end
    return h
end

local function word_stats(text)
    local total  = 0
    local unique = {}
    for word in text:gmatch("%a+") do
        total = total + 1
        unique[word:lower()] = true
    end
    local n_unique = 0
    for _ in pairs(unique) do n_unique = n_unique + 1 end
    return total, n_unique
end

local function alpha_ratio(text)
    local n = #text
    if n == 0 then return 1 end
    local alpha = 0
    for i = 1, n do
        local b = text:byte(i)
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            alpha = alpha + 1
        end
    end
    return alpha / n
end

-- Returns true when > 30% of bytes are high-byte (non-ASCII), indicating
-- a non-Latin writing system where alpha ratio is not meaningful.
local function is_non_latin(text)
    local n = #text
    if n == 0 then return false end
    local high = 0
    for i = 1, n do
        if text:byte(i) > 127 then high = high + 1 end
    end
    return (high / n) > 0.3
end

-- Extract LLM content from an OpenAI-compatible JSON response body.
local function extract_content(body)
    local ok, resp = pcall(cjson.decode, body)
    if not ok or type(resp) ~= "table" then return body end
    local choices = resp.choices
    if choices and choices[1] then
        local msg = choices[1].message
        if msg and type(msg.content) == "string" then return msg.content end
    end
    local content = resp.content
    if content and content[1] and type(content[1].text) == "string" then
        return content[1].text
    end
    return body
end

function M.run(ctx, detector, phase)
    if phase ~= "response" then return { verdict = "pass" } end

    local body = ctx.response_body
    if not body or body == "" then return { verdict = "pass" } end

    local text = extract_content(body)
    if not text or #text < 20 then return { verdict = "pass" } end

    local action          = detector.action or "block"
    local entropy_thresh  = detector.entropy_threshold or 2.5
    local word_rep_thresh = detector.word_repeat_ratio  or 0.15
    local alpha_thresh    = detector.alpha_ratio         or 0.6

    local fired   = 0
    local reasons = {}

    -- Signal 1: Shannon character entropy
    local h = shannon_entropy(text)
    if h < entropy_thresh then
        fired = fired + 1
        reasons[#reasons + 1] = "low_entropy"
    end

    -- Signal 2: word repetition
    local total_words, unique_words = word_stats(text)
    if total_words >= 5 and (unique_words / total_words) < word_rep_thresh then
        fired = fired + 1
        reasons[#reasons + 1] = "word_repetition"
    end

    -- Signal 3: alpha ratio (skipped for non-Latin scripts)
    if not is_non_latin(text) then
        if alpha_ratio(text) < alpha_thresh then
            fired = fired + 1
            reasons[#reasons + 1] = "low_alpha_ratio"
        end
    end

    if fired == 0 then return { verdict = "pass" } end

    local pattern = table.concat(reasons, ",")

    -- 1 signal → always flag; ≥2 → apply configured action
    if fired >= 2 then
        if action == "block" then
            return { verdict = "block", pattern = pattern }
        else
            return { verdict = "flagged", pattern = pattern }
        end
    else
        return { verdict = "flagged", pattern = pattern }
    end
end

return M
