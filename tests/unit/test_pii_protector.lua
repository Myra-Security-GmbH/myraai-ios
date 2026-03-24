-- tests/unit/test_pii_protector.lua
-- Run with: resty tests/runner.lua tests/unit/test_pii_protector.lua
--       or: busted tests/unit/test_pii_protector.lua

package.path = "/home/sas/work/ai-gateway/src/?.lua;" ..
               "/home/sas/work/ai-gateway/src/?/init.lua;" ..
               package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

_G.ngx = {
    log  = function() end,
    WARN = 4,
    ERR  = 3,
    INFO = 2,
    now  = function() return 1711000000.5 end,
    -- Deterministic md5 stub: returns 32 hex chars derived from seed string.
    -- Real ngx.md5 hashes the input; we just need stable 6-char output per seed.
    md5  = function(s)
        -- Use crc-like mixing so different seeds produce visibly different salts.
        local v = 0
        for i = 1, #s do v = (v * 31 + s:byte(i)) % 0x1000000 end
        return string.format("%06x%026x", v, 0)
    end,
    req  = { set_body_data = function() end },
}

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

clear({ "guardrails.pii_protector", "utils.json", "utils.http" })

-- Load real utils.json (uses cjson.safe which is available under resty).
local json_real = require("utils.json")

-- ---------------------------------------------------------------------------
-- HTTP mock factory — installs a utils.http stub returning `response_table`
-- encoded as JSON, or an error if `force_err` is set.
-- ---------------------------------------------------------------------------
local function install_http_mock(response_table, force_err)
    package.loaded["utils.http"]   = nil
    package.preload["utils.http"]  = function()
        return {
            request = function(_opts)
                if force_err then
                    return nil, nil, nil, force_err
                end
                return 200, {}, json_real.encode(response_table), nil
            end
        }
    end
end

local function reload()
    package.loaded["guardrails.pii_protector"] = nil
    return require("guardrails.pii_protector")
end

-- ---------------------------------------------------------------------------
-- Context helpers
-- ---------------------------------------------------------------------------
local function req_ctx(body, request_id)
    return {
        raw_request_body = body or "",
        response_body    = nil,
        pii_token_map    = nil,
        request_id       = request_id or "req-test-1234",
        log_fields       = {},
        gateway_config   = {},
    }
end

local function resp_ctx(response_body, token_map)
    return {
        raw_request_body = nil,
        response_body    = response_body or "",
        pii_token_map    = token_map,
        request_id       = "req-test-1234",
        log_fields       = {},
        gateway_config   = {},
    }
end

local DET = { name = "pii-protect", timeout_ms = 100, fail_open = true }

-- ============================================================================
-- 1. Request phase — no PII found
-- ============================================================================
describe("pii_protector request phase — no PII", function()

    it("returns pass when Presidio finds no entities", function()
        install_http_mock({})
        local d   = reload()
        local ctx = req_ctx('{"messages":[{"role":"user","content":"hello world"}]}')
        local r   = d.run(ctx, DET, "request")
        assert.equal("pass", r.verdict)
        assert.is_nil(ctx.pii_token_map)
    end)

    it("leaves body unchanged when no PII found", function()
        install_http_mock({})
        local d    = reload()
        local body = '{"messages":[{"role":"user","content":"hello world"}]}'
        local ctx  = req_ctx(body)
        d.run(ctx, DET, "request")
        assert.equal(body, ctx.raw_request_body)
    end)

    it("returns pass for empty body", function()
        install_http_mock({})
        local d   = reload()
        local ctx = req_ctx("")
        local r   = d.run(ctx, DET, "request")
        assert.equal("pass", r.verdict)
    end)

    it("returns pass for nil body", function()
        install_http_mock({})
        local d        = reload()
        local ctx      = req_ctx(nil)
        ctx.raw_request_body = nil
        local r        = d.run(ctx, DET, "request")
        assert.equal("pass", r.verdict)
    end)

end)

-- ============================================================================
-- 2. Request phase — PII found and tokenized
-- ============================================================================
describe("pii_protector request phase — PII found", function()

    -- "Please email alice@example.com for details"
    --  0         1         2         3         4
    --  0123456789012345678901234567890123456789012
    -- "alice@example.com" → start=13, end=30
    local BODY1 = "Please email alice@example.com for details"
    local SPAN1 = {{ entity_type = "EMAIL_ADDRESS", start = 13, ["end"] = 30, score = 0.85 }}

    it("returns scrubbed verdict and sets pii_token_map", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        local r   = d.run(ctx, DET, "request")
        assert.equal("scrubbed", r.verdict)
        assert.not_nil(ctx.pii_token_map)
    end)

    it("token format is [MYRA-REDACT-TYPE:XXXXXX:N] with entity type and 6 lowercase hex chars", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        d.run(ctx, DET, "request")
        local tok_count = 0
        for tok in pairs(ctx.pii_token_map) do
            tok_count = tok_count + 1
            assert.not_nil(
                tok:match("^%[MYRA%-REDACT%-[A-Z_]+:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:%d+%]$"),
                "token must match [MYRA-REDACT-TYPE:XXXXXX:N] format, got: " .. tok)
        end
        assert.equal(1, tok_count)
    end)

    it("original value is stored in token_map", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        d.run(ctx, DET, "request")
        local orig
        for _, v in pairs(ctx.pii_token_map) do orig = v end
        assert.equal("alice@example.com", orig)
    end)

    it("original PII is absent from tokenized body", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        d.run(ctx, DET, "request")
        assert.is_nil(ctx.raw_request_body:find("alice@example.com", 1, true),
                      "original PII must not appear in tokenized body")
    end)

    it("token appears in tokenized body", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        d.run(ctx, DET, "request")
        local tok
        for t in pairs(ctx.pii_token_map) do tok = t end
        assert.not_nil(ctx.raw_request_body:find(tok, 1, true),
                       "token must appear in tokenized body")
    end)

    it("pattern field contains entity type name", function()
        install_http_mock(SPAN1)
        local d   = reload()
        local ctx = req_ctx(BODY1)
        local r   = d.run(ctx, DET, "request")
        assert.equal("scrubbed", r.verdict)
        assert.not_nil(r.pattern)
        assert.not_nil(r.pattern:find("EMAIL_ADDRESS", 1, true))
    end)

    it("dedup: same value appearing twice → one token entry, two substitutions", function()
        -- "From alice@example.com to alice@example.com"
        --  start1=5, end1=22; start2=26, end2=43
        local body  = "From alice@example.com to alice@example.com"
        local spans = {
            { entity_type = "EMAIL_ADDRESS", start =  5, ["end"] = 22, score = 0.9 },
            { entity_type = "EMAIL_ADDRESS", start = 26, ["end"] = 43, score = 0.9 },
        }
        install_http_mock(spans)
        local d   = reload()
        local ctx = req_ctx(body)
        d.run(ctx, DET, "request")

        local count = 0
        local tok
        for t in pairs(ctx.pii_token_map) do count = count + 1; tok = t end
        assert.equal(1, count, "same value → 1 token entry")

        -- both occurrences replaced
        local pos, n = 1, 0
        while true do
            local s = ctx.raw_request_body:find(tok, pos, true)
            if not s then break end
            n   = n + 1
            pos = s + 1
        end
        assert.equal(2, n, "token must appear twice in tokenized body")
    end)

    it("overlap: higher-score span wins, lower-score span dropped", function()
        -- Span A: 0–15 score=0.95  Span B: 10–20 score=0.70 (overlaps A)
        local body  = "1234567890ABCDE12345"
        local spans = {
            { entity_type = "TYPE_A", start =  0, ["end"] = 15, score = 0.95 },
            { entity_type = "TYPE_B", start = 10, ["end"] = 20, score = 0.70 },
        }
        install_http_mock(spans)
        local d   = reload()
        local ctx = req_ctx(body)
        d.run(ctx, DET, "request")
        local count = 0
        for _ in pairs(ctx.pii_token_map) do count = count + 1 end
        assert.equal(1, count, "only highest-score non-overlapping span survives")
    end)

    it("multiple distinct values get distinct tokens", function()
        -- "Call 555-0100 or email bob@test.org"
        local body  = "Call 555-0100 or email bob@test.org"
        local spans = {
            { entity_type = "PHONE_NUMBER",  start =  5, ["end"] = 13, score = 0.88 },
            { entity_type = "EMAIL_ADDRESS", start = 23, ["end"] = 34, score = 0.92 },
        }
        install_http_mock(spans)
        local d   = reload()
        local ctx = req_ctx(body)
        d.run(ctx, DET, "request")
        local count = 0
        for _ in pairs(ctx.pii_token_map) do count = count + 1 end
        assert.equal(2, count, "two distinct values → two distinct tokens")
    end)

end)

-- ============================================================================
-- 3. Request phase — Presidio errors
-- ============================================================================
describe("pii_protector request phase — Presidio errors", function()

    it("fail_open=true returns pass on analyzer error", function()
        install_http_mock(nil, "connection refused")
        local d   = reload()
        local ctx = req_ctx("some text")
        local r   = d.run(ctx, { name = "t", fail_open = true }, "request")
        assert.equal("pass", r.verdict)
        assert.is_nil(ctx.pii_token_map)
    end)

    it("fail_open=false returns block on analyzer error", function()
        install_http_mock(nil, "connection refused")
        local d   = reload()
        local ctx = req_ctx("some text")
        local r   = d.run(ctx, { name = "t", fail_open = false }, "request")
        assert.equal("block", r.verdict)
    end)

    it("fail_open defaults to true when not set", function()
        install_http_mock(nil, "timeout")
        local d   = reload()
        local ctx = req_ctx("some text")
        local r   = d.run(ctx, { name = "t" }, "request")
        assert.equal("pass", r.verdict)
    end)

end)

-- ============================================================================
-- 4. Response phase — no token map
-- ============================================================================
describe("pii_protector response phase — no prior PII", function()

    it("returns pass immediately when pii_token_map is nil", function()
        -- Install a mock that would fail if called
        local http_called = false
        package.loaded["utils.http"]  = nil
        package.preload["utils.http"] = function()
            return { request = function() http_called = true; return nil, nil, nil, "nope" end }
        end
        local d   = reload()
        local ctx = resp_ctx('{"choices":[{"message":{"content":"hello"}}]}', nil)
        local r   = d.run(ctx, DET, "response")
        assert.equal("pass", r.verdict)
        assert.is_false(http_called, "Presidio must not be called in response phase")
    end)

    it("returns pass when response body is empty and token map exists", function()
        install_http_mock({})
        local d   = reload()
        local ctx = resp_ctx("", { ["[PII:abc123:1]"] = "alice@example.com" })
        local r   = d.run(ctx, DET, "response")
        assert.equal("pass", r.verdict)
    end)

end)

-- ============================================================================
-- 5. Response phase — token restoration
-- ============================================================================
describe("pii_protector response phase — restoration", function()

    it("restores a single token to original value", function()
        install_http_mock({})
        local d        = reload()
        local token    = "[PII:abc123:1]"
        local original = "alice@example.com"
        local tok_map  = { [token] = original }
        local resp     = string.format('{"content":"The answer is %s"}', token)
        local ctx      = resp_ctx(resp, tok_map)
        local r        = d.run(ctx, DET, "response")
        assert.equal("scrubbed", r.verdict)
        assert.not_nil(ctx.response_body:find(original, 1, true),
                       "original must appear in restored body")
        assert.is_nil(ctx.response_body:find(token, 1, true),
                      "token must be gone after restore")
    end)

    it("restores multiple tokens including duplicate occurrences", function()
        install_http_mock({})
        local d    = reload()
        local tok1 = "[PII:abc123:1]"
        local tok2 = "[PII:abc123:2]"
        local map  = { [tok1] = "alice@example.com", [tok2] = "555-0100" }
        local body = string.format("Contact %s or call %s. Reply to %s.", tok1, tok2, tok1)
        local ctx  = resp_ctx(body, map)
        d.run(ctx, DET, "response")
        -- tok1 appears twice: both should be restored
        local count, pos = 0, 1
        while true do
            local s = ctx.response_body:find("alice@example.com", pos, true)
            if not s then break end
            count = count + 1
            pos   = s + 1
        end
        assert.equal(2, count, "both occurrences of tok1 must be restored")
        assert.not_nil(ctx.response_body:find("555-0100", 1, true))
    end)

    it("returns pass when tokens are absent from response (LLM paraphrased)", function()
        install_http_mock({})
        local d    = reload()
        local map  = { ["[PII:abc123:1]"] = "alice@example.com" }
        local body = '{"content":"I cannot assist with that."}'
        local ctx  = resp_ctx(body, map)
        local r    = d.run(ctx, DET, "response")
        assert.equal("pass", r.verdict)
        assert.equal(body, ctx.response_body, "body must be unchanged")
    end)

    it("does not call Presidio in response phase", function()
        local http_called = false
        package.loaded["utils.http"]  = nil
        package.preload["utils.http"] = function()
            return { request = function() http_called = true; return 200, {}, "[]", nil end }
        end
        local d   = reload()
        local map = { ["[PII:abc123:1]"] = "secret" }
        local ctx = resp_ctx("body with [PII:abc123:1] inside", map)
        d.run(ctx, DET, "response")
        assert.is_false(http_called, "Presidio must not be called in response phase")
    end)

end)

-- ============================================================================
-- 6. Token format and salt uniqueness
-- ============================================================================
describe("pii_protector token format", function()

    it("token embeds entity type: [MYRA-REDACT-SSN:XXXXXX:N]", function()
        local spans = {{ entity_type = "SSN", start = 4, ["end"] = 15, score = 0.99 }}
        install_http_mock(spans)
        local d   = reload()
        -- "SSN 123-45-6789 here"  start=4 end=15 → "123-45-6789"
        local ctx = req_ctx("SSN 123-45-6789 here")
        d.run(ctx, DET, "request")
        for tok in pairs(ctx.pii_token_map) do
            assert.not_nil(
                tok:match("^%[MYRA%-REDACT%-[A-Z_]+:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:%d+%]$"),
                "got: " .. tok)
            assert.not_nil(tok:find("MYRA-REDACT-SSN:", 1, true), "token must embed entity type SSN, got: " .. tok)
        end
    end)

    it("different request_ids produce different salts", function()
        local spans = {{ entity_type = "EMAIL_ADDRESS", start = 0, ["end"] = 10, score = 0.9 }}
        install_http_mock(spans)
        local d    = reload()
        local ctx1 = req_ctx("a@b.com xyz", "request-id-AAA")
        local ctx2 = req_ctx("a@b.com xyz", "request-id-BBB")
        d.run(ctx1, DET, "request")
        d.run(ctx2, DET, "request")
        local tok1, tok2
        for t in pairs(ctx1.pii_token_map) do tok1 = t end
        for t in pairs(ctx2.pii_token_map) do tok2 = t end
        assert.not_nil(tok1)
        assert.not_nil(tok2)
        -- With our stub ngx.md5 mixing on the full seed string (including request_id),
        -- different IDs produce different salts.
        assert.not_equal(tok1, tok2, "different request_ids must produce different tokens")
    end)

end)

-- ============================================================================
-- 7. skip_system_messages — system/assistant content is not tokenized
-- ============================================================================
describe("pii_protector skip_system_messages", function()

    -- Helper: build a minimal chat request body with a system message containing
    -- a known email and a user message containing a different email.
    -- "noreply@anthropic.com" appears in the system role; "alice@example.com"
    -- appears in the user role.
    --
    -- The system content starts at byte 47 in this specific JSON string:
    --   {"messages":[{"role":"system","content":"system noreply@anthropic.com"},
    --                {"role":"user","content":"user alice@example.com"}]}
    local SYSTEM_EMAIL = "noreply@anthropic.com"
    local USER_EMAIL   = "alice@example.com"
    local BODY = string.format(
        '{"messages":[{"role":"system","content":"system %s"},{"role":"user","content":"user %s"}]}',
        SYSTEM_EMAIL, USER_EMAIL
    )

    -- Presidio returns both emails as detected entities.  We work out their
    -- offsets in BODY manually and return them from the mock.
    local sys_start  = BODY:find(SYSTEM_EMAIL, 1, true) - 1  -- 0-based
    local sys_end    = sys_start + #SYSTEM_EMAIL
    local user_start = BODY:find(USER_EMAIL,   1, true) - 1
    local user_end   = user_start + #USER_EMAIL

    local BOTH_SPANS = {
        { entity_type = "EMAIL_ADDRESS", start = sys_start,  ["end"] = sys_end,  score = 1.0 },
        { entity_type = "EMAIL_ADDRESS", start = user_start, ["end"] = user_end, score = 1.0 },
    }

    it("system-message email is NOT tokenized, user-message email IS (default behaviour)", function()
        install_http_mock(BOTH_SPANS)
        local d   = reload()
        local ctx = req_ctx(BODY)
        local r   = d.run(ctx, DET, "request")

        -- At least the user email triggered a scrub
        assert.equal("scrubbed", r.verdict)

        -- Original user email must be gone
        assert.is_nil(ctx.raw_request_body:find(USER_EMAIL, 1, true),
                      "user email must be tokenized")

        -- System email must be preserved (not tokenized)
        assert.not_nil(ctx.raw_request_body:find(SYSTEM_EMAIL, 1, true),
                       "system email must NOT be tokenized")
    end)

    it("only one token entry created (system email excluded, user email tokenized)", function()
        install_http_mock(BOTH_SPANS)
        local d   = reload()
        local ctx = req_ctx(BODY)
        d.run(ctx, DET, "request")

        local count = 0
        for _ in pairs(ctx.pii_token_map) do count = count + 1 end
        assert.equal(1, count, "only the user-role email should produce a token")
    end)

    it("skip_system_messages=false tokenizes both emails", function()
        install_http_mock(BOTH_SPANS)
        local d   = reload()
        local ctx = req_ctx(BODY)
        local det = { name = "pii-protect", timeout_ms = 100, fail_open = true,
                      skip_system_messages = false }
        d.run(ctx, det, "request")

        assert.is_nil(ctx.raw_request_body:find(SYSTEM_EMAIL, 1, true),
                      "system email must also be tokenized when skip_system_messages=false")
        assert.is_nil(ctx.raw_request_body:find(USER_EMAIL, 1, true),
                      "user email must be tokenized when skip_system_messages=false")

        local count = 0
        for _ in pairs(ctx.pii_token_map) do count = count + 1 end
        assert.equal(2, count)
    end)

    it("returns pass when the only detected entity is in a system message", function()
        -- Presidio returns only the system-message email
        local sys_only = {
            { entity_type = "EMAIL_ADDRESS", start = sys_start, ["end"] = sys_end, score = 1.0 },
        }
        install_http_mock(sys_only)
        local d   = reload()
        local ctx = req_ctx(BODY)
        local r   = d.run(ctx, DET, "request")

        assert.equal("pass", r.verdict)
        assert.is_nil(ctx.pii_token_map)
        assert.not_nil(ctx.raw_request_body:find(SYSTEM_EMAIL, 1, true),
                       "system email must be untouched")
    end)

    it("assistant-role content is also excluded by default", function()
        local assistant_email = "bot@service.internal"
        local body2 = string.format(
            '{"messages":[{"role":"assistant","content":"contact %s"},{"role":"user","content":"user %s"}]}',
            assistant_email, USER_EMAIL
        )
        local a_start = body2:find(assistant_email, 1, true) - 1
        local u_start = body2:find(USER_EMAIL, 1, true) - 1
        local spans2  = {
            { entity_type = "EMAIL_ADDRESS", start = a_start, ["end"] = a_start + #assistant_email, score = 1.0 },
            { entity_type = "EMAIL_ADDRESS", start = u_start, ["end"] = u_start + #USER_EMAIL,      score = 1.0 },
        }
        install_http_mock(spans2)
        local d   = reload()
        local ctx = req_ctx(body2)
        d.run(ctx, DET, "request")

        assert.not_nil(ctx.raw_request_body:find(assistant_email, 1, true),
                       "assistant email must NOT be tokenized")
        assert.is_nil(ctx.raw_request_body:find(USER_EMAIL, 1, true),
                      "user email must be tokenized")
    end)

end)

-- ============================================================================
-- 8. allow_list — passed through to Presidio request payload
-- ============================================================================
describe("pii_protector allow_list passthrough", function()

    it("allow_list is included in the Presidio request payload", function()
        local captured_payload

        package.loaded["utils.http"]  = nil
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    captured_payload = require("utils.json").decode(opts.body)
                    return 200, {}, "[]", nil
                end
            }
        end

        local d   = reload()
        local ctx = req_ctx("hello")
        local det = { name = "pii-protect", fail_open = true,
                      allow_list = { "noreply@anthropic.com", "bot@internal" } }
        d.run(ctx, det, "request")

        assert.not_nil(captured_payload)
        assert.same({ "noreply@anthropic.com", "bot@internal" },
                    captured_payload.allow_list,
                    "allow_list must be forwarded to Presidio")
    end)

    it("allow_list_match is forwarded when set", function()
        local captured_payload

        package.loaded["utils.http"]  = nil
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    captured_payload = require("utils.json").decode(opts.body)
                    return 200, {}, "[]", nil
                end
            }
        end

        local d   = reload()
        local ctx = req_ctx("hello")
        local det = { name = "pii-protect", fail_open = true,
                      allow_list = { "noreply@anthropic.com" },
                      allow_list_match = "regex" }
        d.run(ctx, det, "request")

        assert.equal("regex", captured_payload.allow_list_match)
    end)

    it("allow_list absent from payload when not configured", function()
        local captured_payload

        package.loaded["utils.http"]  = nil
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    captured_payload = require("utils.json").decode(opts.body)
                    return 200, {}, "[]", nil
                end
            }
        end

        local d   = reload()
        local ctx = req_ctx("hello")
        d.run(ctx, DET, "request")  -- DET has no allow_list

        assert.is_nil(captured_payload.allow_list,
                      "allow_list must not be sent when not configured")
    end)

end)

-- ============================================================================
-- 9. JSON escape integrity guard
-- ============================================================================
describe("pii_protector JSON escape integrity guard", function()

    -- Regression test: pii_protector sends the raw JSON body to Presidio, so
    -- Presidio's codepoint offsets are relative to the raw bytes including any
    -- \uXXXX escape sequences.  If a span boundary lands inside an escape (e.g.
    -- at the 'u' of \u0040), tokenize_spans would produce \[TOKEN] — an invalid
    -- JSON escape.  The guard must detect this and fall back to "pass".

    it("returns pass when a Presidio span starts inside a \\uXXXX escape", function()
        -- Body: raw JSON containing \u0040 (JSON-escape for @) inside a string.
        local body = '{"messages":[{"role":"user","content":"test\\u0040phone"}]}'

        -- Find the 1-based position of '\' in \u0040 inside the body.
        local backslash_1 = body:find("\\u0040", 1, true)
        assert.not_nil(backslash_1, "test body must contain \\u0040")

        -- The 'u' is immediately after '\'.  In 0-based codepoint terms (what
        -- Presidio returns), the 'u' is at backslash_1 + 1 - 1 = backslash_1.
        local u_pos_0based = backslash_1  -- 0-based: 'u' follows '\' at 1-based (backslash_1+1)

        -- Simulate Presidio detecting a phone starting at 'u' (inside the escape).
        local span_end = u_pos_0based + 9  -- covers "u0040phon"
        local spans = {{ entity_type = "PHONE_NUMBER",
                         start = u_pos_0based, ["end"] = span_end, score = 0.9 }}

        install_http_mock(spans)
        local d   = reload()
        local ctx = req_ctx(body)
        local r   = d.run(ctx, DET, "request")

        -- Guard: tokenization would have produced \[TOKEN] (invalid JSON escape).
        -- pii_protector must fall back to pass rather than forward corrupted JSON.
        assert.equal("pass", r.verdict,
            "must return pass when tokenization would corrupt a JSON escape")
        assert.equal(body, ctx.raw_request_body,
            "raw_request_body must be unchanged")
        assert.is_nil(ctx.pii_token_map,
            "pii_token_map must not be set when guard fires")
    end)

    it("still tokenizes PII that does not touch any \\uXXXX escape", function()
        -- Body with unicode escape elsewhere but PII clearly separated from it.
        -- \u0040 appears before the email; the EMAIL span starts well after it.
        local body = '{"messages":[{"role":"user","content":"note\\u0040: email alice@example.com"}]}'

        -- Find the actual byte position of "alice" in the raw body.
        local alice_1 = body:find("alice@example.com", 1, true)
        assert.not_nil(alice_1, "test body must contain the email")
        local alice_0 = alice_1 - 1  -- convert to 0-based for Presidio

        local spans = {{ entity_type = "EMAIL_ADDRESS",
                         start = alice_0, ["end"] = alice_0 + 17, score = 0.95 }}

        install_http_mock(spans)
        local d   = reload()
        local ctx = req_ctx(body)
        local r   = d.run(ctx, DET, "request")

        -- PII is safely outside the escape; tokenization should succeed.
        assert.equal("scrubbed", r.verdict,
            "PII safely outside \\uXXXX escape must still be tokenized")
        assert.is_nil(ctx.raw_request_body:find("alice@example.com", 1, true),
            "original email must be absent after tokenization")
    end)

end)

-- ============================================================================
-- 10. Orchestrator integration
-- ============================================================================
describe("orchestrator recognises pii_protector type", function()

    it("does not emit 'unknown detector type' warning for pii_protector", function()
        local warned = false
        local orig   = _G.ngx.log
        _G.ngx.log = function(level, ...)
            if level == _G.ngx.WARN then
                local msg = table.concat({...})
                if msg:find("unknown detector type", 1, true) then warned = true end
            end
        end

        install_http_mock({})  -- analyzer returns no entities → pass
        reload()

        -- Clear and reload orchestrator so it picks up the updated MODULES table.
        package.loaded["guardrails.orchestrator"] = nil
        local orch = require("guardrails.orchestrator")

        local ctx = {
            raw_request_body = "hello world",
            response_body    = nil,
            pii_token_map    = nil,
            request_id       = "test-id",
            log_fields       = {},
            gateway_config   = {
                guardrails = { { type = "pii_protector", name = "test", target = "request" } }
            },
        }
        orch.run_phase(ctx, "request")

        _G.ngx.log = orig
        assert.is_false(warned, "orchestrator must not warn about unknown type pii_protector")
    end)

end)
