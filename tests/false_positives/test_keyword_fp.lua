#!/usr/bin/env resty
-- tests/false_positives/test_keyword_fp.lua
-- Measures false positive rates for the keyword detector using a two-tier
-- keyword architecture derived from benchmark data:
--
--   BLOCK tier — high-precision terms with near-zero FP rate on real corpora.
--               Safe to use with action:block, whole_word:true.
--
--   FLAG tier  — educational / ambiguous terms that appear frequently in
--               legitimate text (security education, medical discussion, etc.).
--               Must NOT use action:block. Flag for human review only.
--
-- The test runs both tiers and prints FP rates side-by-side so the cost of
-- promoting a keyword from FLAG→BLOCK is immediately visible.
--
-- Run from repo root:
--   resty tests/false_positives/test_keyword_fp.lua
--
-- Results → tests/false_positives/results/keyword_fp_results.json

package.path = "src/?.lua;src/?/init.lua;" .. package.path

_G.ngx = _G.ngx or {}
ngx.log  = ngx.log  or function() end
ngx.WARN = ngx.WARN or 4
ngx.ERR  = ngx.ERR  or 3
ngx.INFO = ngx.INFO or 2
ngx.req  = ngx.req  or { set_body_data = function() end }

local cjson   = require("cjson")
local keyword = require("guardrails.keyword")

local CORPUS_DIR  = "tests/false_positives/corpus"
local RESULTS_DIR = "tests/false_positives/results"

-- ── Tier definitions ──────────────────────────────────────────────────────────
--
-- Evidence from benchmark run (OR-Bench 1,319 benign prompts):
--
-- High-FP terms (must stay in FLAG tier):
--   "meth"           → 10.4% FP (substring); fires on method/methodology/arithmetic
--   "malware"        → 2.0%  FP (whole_word); legitimate security education
--   "ransomware"     → 1.6%  FP (whole_word); "how does ransomware work?"
--   "phishing"       → 0.8%  FP (whole_word); phishing awareness training
--   "bomb"           → 1.6%  FP (whole_word); calorimeter, photobomb, idiom
--   "attack"         → 0.8%  FP (whole_word); chess, heart attack, cyber
--   "kill"           → 0.5%  FP (whole_word); kill process, idiom
--   "restricted"     → 2.5%  FP (whole_word); "restricted topics" in AI safety text
--   "confidential"   → 0.5%  FP (whole_word); legal/business context
--   "self-harm"      → 1.4%  FP (whole_word); harm-reduction, medical literature
--   "suicide"        → 0.2%  FP (whole_word); mental health support discussions
--
-- Near-zero FP terms (candidates for BLOCK tier):
--   "assassin"       → 0.0%  FP across all corpora
--   "rootkit"        → 0.0%  FP across all corpora
--   "keylogger"      → 0.0%  FP across all corpora
--   "cocaine"        → 0.0%  FP (whole_word)
--   "heroin"         → 0.0%  FP (whole_word)
--   "fentanyl"       → 0.0%  FP (whole_word)
--   "top secret"     → 0.0%  FP across all corpora
--   "internal only"  → 0.0%  FP across all corpora
--   "stab"           → 0.0%  FP (whole_word)

local TIERS = {
    {
        -- ── BLOCK tier ───────────────────────────────────────────────────────
        -- action:block is safe here; these terms do not appear in benign text.
        -- All entries use whole_word:true.
        name        = "block",
        action      = "block",
        whole_word  = true,
        description = "Hard-block tier — near-zero FP, high-confidence harm signal",
        configs = {
            {
                id       = "violence_block",
                category = "violence",
                keywords = { "assassin", "stab", "terrorist" },
                -- excluded: murder (3 FP on XSTest), weapon (4 FP on OR-Bench),
                --           bomb (21 FP), attack (10 FP), kill (6 FP)
            },
            {
                id       = "hacking_block",
                category = "hacking",
                keywords = { "rootkit", "keylogger", "c2", "command and control" },
                -- excluded: ransomware (21 FP), phishing (10 FP), botnet (3 FP),
                --           malware (27 FP), exploit (6 FP), bypass (7 FP)
            },
            {
                id       = "drugs_block",
                category = "drugs",
                keywords = { "cocaine", "heroin", "fentanyl", "oxycodone" },
                -- excluded: meth (137 FP substring / 1 whole_word),
                --           methamphetamine (3 FP), overdose (context-dependent),
                --           narcotic (ambiguous)
            },
            {
                id       = "restricted_block",
                category = "restricted_info",
                keywords = { "top secret", "internal only" },
                -- excluded: confidential (6-7 FP), classified (ambiguous in ML context),
                --           restricted (33 FP), proprietary (legal context)
            },
        },
    },
    {
        -- ── FLAG tier ────────────────────────────────────────────────────────
        -- action:flag only — route to human review. Do NOT promote to block.
        -- These terms appear regularly in legitimate security education,
        -- medical discussion, and general conversation.
        -- All entries use whole_word:true.
        name        = "flag",
        action      = "flag",
        whole_word  = true,
        description = "Flag-only tier — ambiguous terms, human review required",
        configs = {
            {
                id       = "violence_flag",
                category = "violence",
                keywords = { "murder", "weapon", "kill", "bomb", "attack", "stab" },
                -- includes stab as flag (0 FP) to capture broader violence signals
            },
            {
                id       = "hacking_flag",
                category = "hacking",
                keywords = { "ransomware", "phishing", "botnet", "malware",
                             "exploit", "bypass", "hack" },
            },
            {
                id       = "drugs_flag",
                category = "drugs",
                keywords = { "methamphetamine", "overdose", "narcotic" },
                -- note: raw "meth" intentionally excluded even from flag tier;
                -- too many substring collisions even with whole_word
            },
            {
                id       = "restricted_flag",
                category = "restricted_info",
                keywords = { "confidential", "classified", "restricted", "proprietary" },
            },
            {
                id       = "self_harm_flag",
                category = "self_harm",
                keywords = { "suicide", "self-harm", "cutting", "overdose" },
                -- self-harm must never be action:block — users seeking help
                -- should not be hard-blocked; flag for pastoral/human review
            },
        },
    },
}

local CORPUS_FILES = {
    { name = "or_bench_hard", path = CORPUS_DIR .. "/or_bench_hard.json" },
    { name = "xstest_safe",   path = CORPUS_DIR .. "/xstest_safe.json"   },
    { name = "dolly_sample",  path = CORPUS_DIR .. "/dolly_sample.json"  },
    { name = "handcrafted",   path = CORPUS_DIR .. "/handcrafted.json"   },
}

-- ── helpers ───────────────────────────────────────────────────────────────────
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end

local function load_corpus(path)
    local c = read_file(path)
    if not c then return nil end
    local ok, d = pcall(cjson.decode, c)
    return ok and d or nil
end

local function run_detector(prompts, kw_list, whole_word)
    local fp_count  = 0
    local kw_counts = {}

    for _, entry in ipairs(prompts) do
        local text = type(entry) == "table"
            and (entry.prompt or entry.instruction or entry.text or "")
            or  tostring(entry)

        if text ~= "" then
            local ctx = { raw_request_body = text, log_fields = {} }
            local det = {
                action     = "flag",   -- always flag for measurement; action label is metadata
                keywords   = kw_list,
                whole_word = whole_word,
            }
            local r = keyword.run(ctx, det, "request")
            if r.verdict ~= "pass" then
                fp_count = fp_count + 1
                local kw = r.pattern or "unknown"
                kw_counts[kw] = (kw_counts[kw] or 0) + 1
            end
        end
    end
    return fp_count, kw_counts
end

-- ── load corpora ──────────────────────────────────────────────────────────────
local loaded_corpora = {}
for _, c in ipairs(CORPUS_FILES) do
    local prompts = load_corpus(c.path)
    if prompts then
        loaded_corpora[#loaded_corpora + 1] = { name = c.name, prompts = prompts }
    else
        print(string.format("SKIP %-20s (not found)", c.name))
    end
end

-- ── run ───────────────────────────────────────────────────────────────────────
local all_results = {}
local LINE = string.rep("─", 88)

for _, tier in ipairs(TIERS) do
    print("\n" .. LINE)
    print(string.format("TIER: %s  (action:%s, whole_word:true)", tier.name:upper(), tier.action))
    print(tier.description)
    print(LINE)
    print(string.format("  %-28s %-20s %8s %8s %7s  %s",
        "config", "corpus", "total", "fp_count", "fp%", "top trigger"))
    print("  " .. string.rep("─", 82))

    for _, cfg in ipairs(tier.configs) do
        for _, corpus in ipairs(loaded_corpora) do
            local fp_count, kw_counts = run_detector(
                corpus.prompts, cfg.keywords, tier.whole_word)
            local total   = #corpus.prompts
            local fp_rate = total > 0 and (fp_count / total * 100) or 0

            -- Find top trigger
            local top_kw, top_n = "—", 0
            for kw, n in pairs(kw_counts) do
                if n > top_n then top_kw, top_n = kw, n end
            end
            local top_str = top_n > 0
                and string.format("%s (%d)", top_kw, top_n)
                or  "—"

            -- Flag if FP rate exceeds thresholds for the tier
            local warn = ""
            if tier.name == "block" and fp_rate > 0.5 then
                warn = "  ⚠ high for block tier"
            elseif tier.name == "flag" and fp_rate > 5.0 then
                warn = "  ⚠ very high"
            end

            print(string.format("  %-28s %-20s %8d %8d %6.1f%%  %s%s",
                cfg.id, corpus.name, total, fp_count, fp_rate, top_str, warn))

            all_results[#all_results + 1] = {
                corpus       = corpus.name,
                detector     = "keyword",
                tier         = tier.name,
                intended_action = tier.action,
                config_id    = cfg.id,
                category     = cfg.category,
                keyword_list = cfg.keywords,
                whole_word   = tier.whole_word,
                total        = total,
                fp_count     = fp_count,
                fp_rate      = math.floor(fp_rate * 100) / 100,
                top_keywords = kw_counts,
            }
        end
    end
end

print("\n" .. LINE)

-- ── summary: block-tier max FP rate per corpus ────────────────────────────────
print("\nBlock-tier summary (max FP rate — must stay low to justify action:block):")
local block_max = {}
for _, r in ipairs(all_results) do
    if r.tier == "block" then
        local key = r.corpus
        if not block_max[key] or r.fp_rate > block_max[key].fp_rate then
            block_max[key] = r
        end
    end
end
for _, corpus in ipairs(loaded_corpora) do
    local worst = block_max[corpus.name]
    if worst then
        local marker = worst.fp_rate > 0.5 and "  ⚠" or "  ✓"
        print(string.format("  %-20s  worst: %-28s  %.1f%%%s",
            corpus.name, worst.config_id, worst.fp_rate, marker))
    end
end

-- ── write results ─────────────────────────────────────────────────────────────
os.execute("mkdir -p " .. RESULTS_DIR)
local out_path = RESULTS_DIR .. "/keyword_fp_results.json"
local out = io.open(out_path, "w")
if out then
    out:write(cjson.encode(all_results))
    out:close()
    print("\nResults → " .. out_path)
end
