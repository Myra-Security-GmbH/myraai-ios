#!/usr/bin/env resty
-- tests/false_positives/test_regex_fp.lua
-- Measures false positive rates for the regex detector across pattern configurations.
--
-- Run from repo root:
--   resty tests/false_positives/test_regex_fp.lua
--
-- Corpus files are loaded from tests/false_positives/corpus/*.json.
-- Results are written to tests/false_positives/results/regex_fp_results.json.

-- ── package path ─────────────────────────────────────────────────────────────
package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ── ngx shim (resty CLI has ngx, but set_body_data requires a request ctx) ───
_G.ngx = _G.ngx or {}
ngx.log  = ngx.log  or function() end
ngx.WARN = ngx.WARN or 4
ngx.ERR  = ngx.ERR  or 3
ngx.INFO = ngx.INFO or 2
ngx.req  = ngx.req  or { set_body_data = function() end }

-- ── modules ──────────────────────────────────────────────────────────────────
local cjson   = require("cjson")
local regex   = require("guardrails.regex")
local pat_lib = require("guardrails.patterns")  -- ensure aba_check is loaded

local CORPUS_DIR = "tests/false_positives/corpus"
local RESULTS_DIR = "tests/false_positives/results"

-- ── detector configurations to sweep ─────────────────────────────────────────
local CONFIGS = {
    { id = "pii_basic",         patterns = { "pii_basic" } },
    { id = "hipaa_structured",  patterns = { "hipaa_structured" } },
    { id = "gdpr_structured",   patterns = { "gdpr_structured" } },
    { id = "pci_pan",           patterns = { "pci_pan" } },
    { id = "credentials",       patterns = { "credentials" } },
    { id = "all_sets",          patterns = { "pii_basic", "hipaa_structured", "gdpr_structured", "pci_pan", "credentials" } },
    -- Individual pattern sweep — one pattern at a time
    -- Benchmarked 6 (high-FP suspects)
    { id = "phone_only",        patterns = { "phone" } },
    { id = "ssn_only",          patterns = { "ssn" } },
    { id = "dob_only",          patterns = { "dob" } },
    { id = "ip_only",           patterns = { "ip_address" } },
    { id = "routing_only",      patterns = { "routing_number" } },
    { id = "email_only",        patterns = { "email" } },
    -- Previously untested individual patterns
    { id = "cc_only",           patterns = { "cc" } },
    { id = "cvv_only",          patterns = { "cvv" } },
    { id = "card_expiry_only",  patterns = { "card_expiry" } },
    { id = "iban_only",         patterns = { "iban" } },
    { id = "mrn_only",          patterns = { "mrn" } },
    { id = "npi_only",          patterns = { "npi" } },
    { id = "national_id_only",  patterns = { "national_id" } },
    { id = "passport_only",     patterns = { "passport_number" } },
    { id = "api_key_only",      patterns = { "api_key" } },
    { id = "jwt_only",          patterns = { "jwt" } },
}

local CORPUS_FILES = {
    { name = "or_bench_hard", path = CORPUS_DIR .. "/or_bench_hard.json" },
    { name = "xstest_safe",   path = CORPUS_DIR .. "/xstest_safe.json"   },
    { name = "dolly_sample",  path = CORPUS_DIR .. "/dolly_sample.json"  },
    { name = "handcrafted",   path = CORPUS_DIR .. "/handcrafted.json"   },
}

-- ── helpers ───────────────────────────────────────────────────────────────────
local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function load_corpus(path)
    local content, err = read_file(path)
    if not content then return nil, err end
    local ok, data = pcall(cjson.decode, content)
    if not ok then return nil, "json parse error: " .. tostring(data) end
    return data
end

local function wrap_body(prompt)
    -- Wrap prompt as an OpenAI-compat JSON body, matching what the gateway sees.
    return cjson.encode({ messages = { { role = "user", content = prompt } } })
end

local function top_n(counts, n)
    local list = {}
    for k, v in pairs(counts) do list[#list + 1] = { name = k, count = v } end
    table.sort(list, function(a, b) return a.count > b.count end)
    local result = {}
    for i = 1, math.min(n, #list) do
        result[list[i].name] = list[i].count
    end
    return result
end

-- ── main ──────────────────────────────────────────────────────────────────────
local all_results = {}
local total_runs = 0
local start_time = os.clock()

print(string.rep("─", 72))
print(string.format("%-30s %-22s  %8s  %8s  %6s", "config", "corpus", "total", "fp_count", "fp%"))
print(string.rep("─", 72))

for _, corpus in ipairs(CORPUS_FILES) do
    local prompts, err = load_corpus(corpus.path)
    if not prompts then
        print(string.format("SKIP %-25s  (%s)", corpus.name, err or "not found"))
    else
        for _, cfg in ipairs(CONFIGS) do
            local fp_count = 0
            local pattern_counts = {}

            for _, entry in ipairs(prompts) do
                local text = type(entry) == "table"
                    and (entry.prompt or entry.instruction or entry.text or "")
                    or  tostring(entry)

                if text ~= "" then
                    local body = wrap_body(text)
                    local ctx  = { raw_request_body = body, log_fields = {} }
                    local det  = { action = "flag", patterns = cfg.patterns }
                    local r    = regex.run(ctx, det, "request")

                    if r.verdict ~= "pass" then
                        fp_count = fp_count + 1
                        local pat = r.pattern or "unknown"
                        pattern_counts[pat] = (pattern_counts[pat] or 0) + 1
                    end
                end
            end

            local total   = #prompts
            local fp_rate = total > 0 and (fp_count / total * 100) or 0

            print(string.format("%-30s %-22s  %8d  %8d  %5.1f%%",
                cfg.id, corpus.name, total, fp_count, fp_rate))

            all_results[#all_results + 1] = {
                corpus       = corpus.name,
                detector     = "regex",
                config_id    = cfg.id,
                total        = total,
                fp_count     = fp_count,
                fp_rate      = math.floor(fp_rate * 100) / 100,
                top_patterns = top_n(pattern_counts, 5),
            }
            total_runs = total_runs + 1
        end
    end
end

print(string.rep("─", 72))
print(string.format("Completed %d runs in %.2fs", total_runs, os.clock() - start_time))

-- ── write results ─────────────────────────────────────────────────────────────
os.execute("mkdir -p " .. RESULTS_DIR)
local out_path = RESULTS_DIR .. "/regex_fp_results.json"
local out = io.open(out_path, "w")
if out then
    out:write(cjson.encode(all_results))
    out:close()
    print("\nResults → " .. out_path)
else
    io.stderr:write("WARNING: could not write results to " .. out_path .. "\n")
end
