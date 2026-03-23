-- guardrails/contains_code.lua — Tier 1 code-detection guardrail
-- Detects programming language code in request or response bodies.
--
-- Two signal layers:
--   1. Markdown code fences (```sql, ```python, …) — single fence = trigger
--   2. Structural heuristics per language (patterns like "SELECT .+ FROM")
--
-- Config fields:
--   languages    []string  — filter to specific languages; omit = detect any
--   min_signals  integer   — minimum signals to trigger (default 1)
--   action       string    — "block" | "flag" (default "block")
--
-- Supported language codes: sql, python, javascript, bash, html, lua

local M = {}

local LANGUAGES = {
    sql = {
        fences   = { "sql", "mysql", "postgresql", "sqlite", "psql" },
        patterns = {
            "SELECT%s+.+%s+FROM%s+%w+",
            "INSERT%s+INTO%s+%w+",
            "UPDATE%s+%w+%s+SET%s+",
            "DELETE%s+FROM%s+%w+",
            "CREATE%s+TABLE",
            "DROP%s+TABLE",
            "ALTER%s+TABLE",
        },
    },
    python = {
        fences   = { "python", "py", "python3" },
        patterns = {
            "def%s+%w+%s*%(.-%)%s*:",
            "import%s+%w+",
            "from%s+%w[%w%.]*%s+import",
            "class%s+%w+%s*[:(]",
            "if%s+__name__%s*==%s*['\"]__main__['\"]",
            "@%w+%s*\n",
        },
    },
    javascript = {
        fences   = { "javascript", "js", "typescript", "ts", "jsx", "tsx", "node" },
        patterns = {
            "const%s+%w+%s*=",
            "let%s+%w+%s*=",
            "function%s+%w+%s*%(",
            "=>%s*{",
            "require%(.-%)%s*;",
            "import%s+.+%s+from%s+['\"]",
            "module%.exports%s*=",
        },
    },
    bash = {
        fences   = { "bash", "sh", "shell", "zsh", "fish" },
        patterns = {
            "#!/bin/bash",
            "#!/usr/bin/env%s+bash",
            "#!/bin/sh",
            "%$%(.-%)%s",
            "if%s+%[%[",
            "for%s+%w+%s+in%s+",
            "echo%s+['\"]",
        },
    },
    html = {
        fences   = { "html", "htm", "xml", "svg" },
        patterns = {
            "<!DOCTYPE%s+html",
            "<html[%s>]",
            "<head[%s>]",
            "<body[%s>]",
            "<div[%s>]",
            "<%w+%s+class=['\"]",
        },
    },
    lua = {
        fences   = { "lua" },
        patterns = {
            "local%s+function%s+%w+",
            "local%s+%w+%s*=%s*require",
            "function%s+%w+%.%w+%s*%(",
            "ngx%.log%(",
        },
    },
}

-- Build fence-name → language code map
local FENCE_MAP = {}
for lang, def in pairs(LANGUAGES) do
    for _, alias in ipairs(def.fences) do
        FENCE_MAP[alias:lower()] = lang
    end
end

local function get_body(ctx, phase)
    return phase == "response" and ctx.response_body or ctx.raw_request_body
end

local function count_signals(text, lang_filter)
    local signals = {}

    -- Layer 1: markdown code fences
    for fence_name in text:gmatch("```([%w+%-]*)") do
        local lang = FENCE_MAP[fence_name:lower()]
        if lang and (not lang_filter or lang_filter[lang]) then
            signals[#signals + 1] = { lang = lang, kind = "fence", pattern = "```" .. fence_name }
        end
    end

    -- Track which langs already matched via fence (skip heuristics for them)
    local fence_langs = {}
    for _, s in ipairs(signals) do fence_langs[s.lang] = true end

    -- Layer 2: structural heuristics
    for lang, def in pairs(LANGUAGES) do
        if not fence_langs[lang] and (not lang_filter or lang_filter[lang]) then
            local first_pat
            for _, pat in ipairs(def.patterns) do
                if text:find(pat) then
                    first_pat = pat
                    break
                end
            end
            if first_pat then
                signals[#signals + 1] = { lang = lang, kind = "heuristic", pattern = first_pat }
            end
        end
    end

    return signals
end

function M.run(ctx, detector, phase)
    local body = get_body(ctx, phase)
    if not body or body == "" then return { verdict = "pass" } end

    local action      = detector.action or "block"
    local min_signals = detector.min_signals or 1

    local lang_filter
    if detector.languages and #detector.languages > 0 then
        lang_filter = {}
        for _, l in ipairs(detector.languages) do
            lang_filter[l:lower()] = true
        end
    end

    local signals = count_signals(body, lang_filter)
    if #signals < min_signals then return { verdict = "pass" } end

    local s      = signals[1]
    local reason = s.lang .. ":" .. s.kind

    if action == "block" then
        return { verdict = "block", pattern = reason }
    else
        return { verdict = "flagged", pattern = reason }
    end
end

return M
