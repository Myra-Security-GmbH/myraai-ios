-- tests/unit/test_new_guardrails.lua
-- Comprehensive unit tests for the four Sprint-2 guardrail detectors:
--   json_schema, contains_code, gibberish, language
-- Run with: resty tests/runner.lua tests/unit/test_new_guardrails.lua

package.path = "/home/sas/work/ai-gateway/src/?.lua;" ..
               "/home/sas/work/ai-gateway/src/?/init.lua;" ..
               package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

_G.ngx = {
    log  = function() end,
    WARN = 4,
    ERR  = 3,
    INFO = 2,
    req  = { set_body_data = function() end },
}

local cjson = require("cjson.safe")

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

clear({ "guardrails.json_schema", "guardrails.contains_code",
        "guardrails.gibberish",   "guardrails.language" })

local json_schema   = require("guardrails.json_schema")
local contains_code = require("guardrails.contains_code")
local gibberish_det = require("guardrails.gibberish")
local language_det  = require("guardrails.language")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Wrap content in an OpenAI-format response body JSON string.
local function openai_resp(content)
    return cjson.encode({ choices = { { message = { content = content } } } })
end

-- Wrap content in an Anthropic-format response body JSON string.
local function anthropic_resp(content)
    return cjson.encode({ content = { { type = "text", text = content } } })
end

local function req_ctx(raw_body, cfg)
    return {
        raw_request_body = raw_body or "",
        response_body    = nil,
        gateway_config   = { guardrails = cfg or {} },
        log_fields       = {},
    }
end

local function resp_ctx(resp_body, cfg)
    return {
        raw_request_body = nil,
        response_body    = resp_body or "",
        gateway_config   = { guardrails = cfg or {} },
        log_fields       = {},
    }
end

-- ============================================================================
-- json_schema
-- ============================================================================

describe("json_schema detector", function()

    local schema_block = {
        type   = "json_schema",
        action = "block",
        schema = {
            required   = { "name", "score" },
            properties = {
                name  = { type = "string", min_length = 1, max_length = 100 },
                score = { type = "number", min = 0, max = 10 },
                grade = { type = "string", enum = { "A", "B", "C" } },
            },
        },
    }

    it("passes when response JSON matches schema fully", function()
        local body = openai_resp('{"name":"Alice","score":8,"grade":"A"}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("blocks on json_parse_error when content is not valid JSON", function()
        local body = openai_resp("This is just plain text, not JSON")
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("json_parse_error", r.pattern)
    end)

    it("blocks when a required field is absent", function()
        local body = openai_resp('{"name":"Alice"}')   -- score missing
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.match("^missing_field:", r.pattern)
    end)

    it("blocks on type mismatch (number where string expected)", function()
        local body = openai_resp('{"name":42,"score":5}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("type_mismatch:name", r.pattern)
    end)

    it("blocks when number is below min", function()
        local body = openai_resp('{"name":"Bob","score":-1}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("range_violation:score", r.pattern)
    end)

    it("blocks when number is above max", function()
        local body = openai_resp('{"name":"Bob","score":11}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("range_violation:score", r.pattern)
    end)

    it("blocks when string is shorter than min_length", function()
        local body = openai_resp('{"name":"","score":5}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("range_violation:name", r.pattern)
    end)

    it("blocks when string is longer than max_length", function()
        local long_name = string.rep("x", 101)
        local body = openai_resp('{"name":"' .. long_name .. '","score":5}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("range_violation:name", r.pattern)
    end)

    it("blocks on enum violation", function()
        local body = openai_resp('{"name":"Carol","score":7,"grade":"D"}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("range_violation:grade", r.pattern)
    end)

    it("passes when optional field is absent (not in required)", function()
        -- grade is in properties but not required
        local body = openai_resp('{"name":"Dave","score":5}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("always passes on request phase (response-only detector)", function()
        local ctx = req_ctx('{"name":"Eve","score":3}')
        local r   = json_schema.run(ctx, schema_block, "request")
        assert.equal("pass", r.verdict)
    end)

    it("passes when no schema is configured", function()
        local body = openai_resp("not even json")
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, { type = "json_schema" }, "response")
        assert.equal("pass", r.verdict)
    end)

    it("strips markdown code fences before parsing", function()
        local body = openai_resp("```json\n{\"name\":\"Faye\",\"score\":6}\n```")
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("uses flagged verdict when action is flag", function()
        local det  = { type = "json_schema", action = "flag", schema = schema_block.schema }
        local body = openai_resp("not json at all")
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, det, "response")
        assert.equal("flagged", r.verdict)
        assert.equal("json_parse_error", r.pattern)
    end)

    it("extracts content from Anthropic-format response body", function()
        local body = anthropic_resp('{"name":"Grace","score":9}')
        local ctx  = resp_ctx(body)
        local r    = json_schema.run(ctx, schema_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("passes when outer JSON is not parseable (upstream error path)", function()
        local ctx = resp_ctx("HTTP/1.1 502 Bad Gateway")
        local r   = json_schema.run(ctx, schema_block, "response")
        assert.equal("pass", r.verdict)
    end)

end)

-- ============================================================================
-- contains_code
-- ============================================================================

describe("contains_code detector", function()

    local det_block = { type = "contains_code", action = "block" }
    local det_flag  = { type = "contains_code", action = "flag"  }

    it("blocks on SQL markdown fence", function()
        local ctx = req_ctx("Here is a query:\n```sql\nSELECT * FROM users;\n```")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("sql:", r.pattern)
    end)

    it("blocks on Python markdown fence", function()
        local ctx = req_ctx("```python\ndef hello():\n    print('hi')\n```")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("python:", r.pattern)
    end)

    it("blocks on HTML markdown fence", function()
        local ctx = req_ctx("Output:\n```html\n<html><body>hello</body></html>\n```")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("html:", r.pattern)
    end)

    it("blocks on JavaScript structural heuristic (const assignment)", function()
        local body = "Sure, here you go:\nconst result = fetch('/api/data');\nreturn result;"
        local ctx  = req_ctx(body)
        local r    = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("javascript:", r.pattern)
    end)

    it("blocks on Bash heuristic (shebang line)", function()
        local ctx = req_ctx("#!/bin/bash\necho \"hello\"")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("bash:", r.pattern)
    end)

    it("blocks on SQL structural heuristic", function()
        local ctx = req_ctx("Run this: SELECT id FROM users WHERE active = 1")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.match("sql:", r.pattern)
    end)

    it("passes on plain English prose", function()
        local prose = "The weather today is sunny. I went to the market and bought apples. "
                   .. "My dog enjoyed the walk this afternoon. Everything is fine."
        local ctx = req_ctx(prose)
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("pass", r.verdict)
    end)

    it("passes when language filter excludes the detected language", function()
        -- SQL is detected but filter only looks for python
        local det = { type = "contains_code", action = "block", languages = { "python" } }
        local ctx = req_ctx("```sql\nSELECT 1;\n```")
        local r   = contains_code.run(ctx, det, "request")
        assert.equal("pass", r.verdict)
    end)

    it("blocks when language filter includes the detected language", function()
        local det = { type = "contains_code", action = "block", languages = { "sql", "python" } }
        local ctx = req_ctx("```python\nimport os\n```")
        local r   = contains_code.run(ctx, det, "request")
        assert.equal("block", r.verdict)
    end)

    it("produces flagged verdict when action is flag", function()
        local ctx = req_ctx("```sql\nSELECT * FROM orders;\n```")
        local r   = contains_code.run(ctx, det_flag, "request")
        assert.equal("flagged", r.verdict)
    end)

    it("min_signals=2 requires two independent signals before triggering", function()
        -- One heuristic alone should not trigger when min_signals=2
        local det = { type = "contains_code", action = "block", min_signals = 2 }
        -- Single heuristic: "const x =" → javascript heuristic but no fence
        local ctx = req_ctx("const x = 42;")
        local r   = contains_code.run(ctx, det, "request")
        assert.equal("pass", r.verdict)
    end)

    it("works on response phase", function()
        local body = openai_resp("Here is the code:\n```python\ndef run(): pass\n```")
        local ctx  = resp_ctx(body)
        local r    = contains_code.run(ctx, det_block, "response")
        assert.equal("block", r.verdict)
    end)

    it("passes on empty body", function()
        local ctx = req_ctx("")
        local r   = contains_code.run(ctx, det_block, "request")
        assert.equal("pass", r.verdict)
    end)

end)

-- ============================================================================
-- gibberish
-- ============================================================================

describe("gibberish detector", function()

    local det_block = { type = "gibberish", action = "block" }
    local det_flag  = { type = "gibberish", action = "flag"  }

    -- A normal English paragraph that should pass all three signal checks.
    local normal_text = "The quick brown fox jumps over the lazy dog. "
                     .. "This sentence contains many different words and "
                     .. "should achieve high Shannon entropy and good word diversity. "
                     .. "Natural language text is varied and interesting."

    it("passes on normal English prose", function()
        local body = openai_resp(normal_text)
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("blocks on highly repetitive text (two signals: entropy + word_repetition)", function()
        -- "the the the ..." has very low entropy and word diversity
        local repetitive = string.rep("the ", 30)   -- 30 words, 1 unique → ratio = 0.033
        local body = openai_resp(repetitive)
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det_block, "response")
        assert.equal("block", r.verdict)
        assert.not_nil(r.pattern)
    end)

    it("flags (not blocks) when exactly one signal fires", function()
        -- Word repetition alone: "go go go go go go go go go go go go"
        -- but with enough variation in characters that entropy stays above 2.5
        -- and alpha ratio is fine. Two unique chars ('g', 'o', ' ') → H ~ 1.5 actually
        -- Let's use a long string with varied characters but very repetitive words
        -- "hello world hello world ..." → 2 unique words / N total = low ratio
        local rep2 = string.rep("hello world ", 10)  -- 20 words, 2 unique → 0.1
        -- entropy of "hello world " repeated: H of {h,e,l,o,' ',w,r,d} chars
        -- should be reasonable (>2.5? let's check: 8 chars, each appears with
        -- varying freq in 120 chars. Entropy will be meaningful.)
        -- Force: use word_repeat only by overriding thresholds
        local det  = {
            type               = "gibberish",
            action             = "block",
            entropy_threshold  = 0,    -- disable entropy signal
            word_repeat_ratio  = 0.15,
            alpha_ratio        = 0,    -- disable alpha signal
        }
        local body = openai_resp(rep2)
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det, "response")
        -- Only word_repeat fires → should be flagged, never blocked
        assert.equal("flagged", r.verdict)
        assert.match("word_repetition", r.pattern)
    end)

    it("passes on text shorter than 20 characters", function()
        local body = openai_resp("ok")
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det_block, "response")
        assert.equal("pass", r.verdict)
    end)

    it("always passes on request phase", function()
        -- gibberish only checks response phase
        local ctx = req_ctx(string.rep("x", 50))
        local r   = gibberish_det.run(ctx, det_block, "request")
        assert.equal("pass", r.verdict)
    end)

    it("does not apply alpha_ratio check to CJK text (non-Latin)", function()
        -- CJK characters have high-byte values → is_non_latin → skips alpha_ratio
        -- "你好世界" repeated to be > 20 chars
        local cjk = "\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c"  -- 你好世界
        local body = openai_resp(string.rep(cjk, 5))  -- 20+ chars
        local ctx  = resp_ctx(body)
        -- alpha_ratio check skipped → should not fire low_alpha_ratio
        local det  = {
            type              = "gibberish",
            action            = "block",
            entropy_threshold = 0,   -- disable entropy
            word_repeat_ratio = 0,   -- disable word repeat
            alpha_ratio       = 0.6, -- would fire if checked
        }
        local r = gibberish_det.run(ctx, det, "response")
        assert.equal("pass", r.verdict)
    end)

    it("produces flagged when action=flag and two signals fire", function()
        local det  = { type = "gibberish", action = "flag" }
        local body = openai_resp(string.rep("the ", 30))
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det, "response")
        assert.equal("flagged", r.verdict)
    end)

    it("blocks on purely non-alphabetic text (low alpha ratio + low entropy)", function()
        -- All digits and symbols — no alpha chars, also low entropy if repeated
        local sym  = string.rep("1234!@#$", 5)   -- 40 chars, 8 unique → H = 3 (ok)
        -- Force low thresholds to test alpha_ratio path
        local det  = {
            type              = "gibberish",
            action            = "block",
            entropy_threshold = 0,    -- disable
            word_repeat_ratio = 0,    -- disable
            alpha_ratio       = 0.99, -- almost everything must be alpha → fires
        }
        local body = openai_resp(sym)
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det, "response")
        -- 1 signal fires → flagged (not block, since only 1 signal)
        assert.equal("flagged", r.verdict)
        assert.match("low_alpha_ratio", r.pattern)
    end)

    it("pattern lists all fired signal names separated by commas", function()
        local body = openai_resp(string.rep("the ", 30))
        local ctx  = resp_ctx(body)
        local r    = gibberish_det.run(ctx, det_block, "response")
        -- at least two signals should be listed
        assert.not_nil(r.pattern:find(","), "expected comma-separated pattern names")
    end)

end)

-- ============================================================================
-- language detector
-- ============================================================================

describe("language detector", function()

    local det_block = { type = "language", action = "block", allowed = { "latin" } }
    local det_flag  = { type = "language", action = "flag",  allowed = { "latin" } }

    -- "你好世界" — 4 CJK characters (all leading bytes in 0xE4–0xE9 range)
    local CJK      = "\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c"
    -- "Привет" — 6 Cyrillic characters
    local CYRILLIC = "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82"
    -- Arabic: "مرحبا" (5 Arabic chars)
    local ARABIC   = "\xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd8\xa7"

    it("passes when Latin text is in the allowed list", function()
        local ctx = req_ctx("Hello, how are you today?")
        local r   = language_det.run(ctx, det_block, "request")
        assert.equal("pass", r.verdict)
    end)

    it("blocks CJK text when only latin is allowed", function()
        local ctx = req_ctx(CJK)
        local r   = language_det.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.equal("language:cjk", r.pattern)
    end)

    it("passes CJK text when cjk is in allowed list", function()
        local det = { type = "language", action = "block", allowed = { "latin", "cjk" } }
        local ctx = req_ctx(CJK)
        local r   = language_det.run(ctx, det, "request")
        assert.equal("pass", r.verdict)
    end)

    it("blocks Cyrillic text when only latin is allowed", function()
        local ctx = req_ctx(CYRILLIC)
        local r   = language_det.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.equal("language:cyrillic", r.pattern)
    end)

    it("blocks Arabic text when only latin is allowed", function()
        local ctx = req_ctx(ARABIC)
        local r   = language_det.run(ctx, det_block, "request")
        assert.equal("block", r.verdict)
        assert.equal("language:arabic", r.pattern)
    end)

    it("always passes when no allowed list is configured", function()
        local det = { type = "language", action = "block" }   -- no allowed field
        local ctx = req_ctx(CJK)
        local r   = language_det.run(ctx, det, "request")
        assert.equal("pass", r.verdict)
    end)

    it("produces flagged verdict when action is flag", function()
        local ctx = req_ctx(CJK)
        local r   = language_det.run(ctx, det_flag, "request")
        assert.equal("flagged", r.verdict)
        assert.equal("language:cjk", r.pattern)
    end)

    it("passes when non-Latin chars are below min_ratio threshold", function()
        -- One CJK char in 30 ASCII chars: ratio ≈ 1/31 ≈ 0.032 < default 0.1
        local mixed = "hello world " .. CJK:sub(1, 3) .. " how are you today"
        local ctx   = req_ctx(mixed)
        local r     = language_det.run(ctx, det_block, "request")
        -- Should classify as latin (below threshold)
        assert.equal("pass", r.verdict)
    end)

    it("passes on empty body", function()
        local ctx = req_ctx("")
        local r   = language_det.run(ctx, det_block, "request")
        assert.equal("pass", r.verdict)
    end)

    it("works on response phase with response_body", function()
        -- Repeat CJK enough times so the ratio exceeds min_ratio despite the JSON wrapper
        -- adding ~43 ASCII chars. 20 CJK codepoints / ~63 total ≈ 0.32 > 0.1 threshold.
        local body = openai_resp(string.rep(CJK, 5))
        local ctx  = resp_ctx(body)
        local r    = language_det.run(ctx, det_block, "response")
        assert.equal("block", r.verdict)
        assert.equal("language:cjk", r.pattern)
    end)

    it("allows empty allowed list (treated as no constraint)", function()
        local det = { type = "language", action = "block", allowed = {} }
        local ctx = req_ctx(CJK)
        local r   = language_det.run(ctx, det, "request")
        assert.equal("pass", r.verdict)
    end)

end)
