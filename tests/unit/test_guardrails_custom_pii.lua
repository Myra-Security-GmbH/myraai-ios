-- tests/unit/test_guardrails_custom_pii.lua — guardrails/custom_pii.lua
-- Run with: resty tests/runner.lua tests/unit/test_guardrails_custom_pii.lua
--
-- Coverage:
--   1. collect_texts: string content, block arrays, prompt field
--   2. replace_all: basic, case-insensitive (default), case-sensitive, whole-word
--   3. request phase: tokenizes keywords, updates body, returns scrubbed verdict
--   4. request phase: deduplication — same keyword → same token across fields
--   5. request phase: no-op when keyword absent → pass
--   6. request phase: sets pii_force_buffered for streaming compat
--   7. request phase: initialises / increments custom_pii_counter
--   8. response phase: restores MYRA-CUSTOM tokens
--   9. response phase: ignores non-MYRA-CUSTOM tokens (pii_protector tokens)
--  10. response phase: no-op when response_body is empty

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _log_buf = {}
_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    md5    = function(s)
        -- Deterministic stub: produce a hex string from input
        local v = 0
        for i = 1, #s do v = (v * 31 + s:byte(i)) % 0x1000000 end
        return string.format("%06x%026x", v, 0)
    end,
    ERR = 0, WARN = 1, INFO = 2,
    req = { read_body=function() end, get_body_data=function() return nil end,
            get_body_file=function() return nil end },
}

for _, n in ipairs({"guardrails.custom_pii","utils.json","utils.request","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end
package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null,
             sanitize_surrogates=function(s) return s end }
end
package.preload["utils.request"] = function()
    return { read_body=function() return nil end }
end

local custom_pii = require("guardrails.custom_pii")

local function reset()
    _log_buf = {}
end

local function make_ctx(messages, stream)
    local body = { model="gpt-4o",
                   messages=messages or {{role="user",content="hello"}},
                   stream=stream or false }
    return {
        request_id     = "req-001",
        is_compat      = true,
        request_body   = body,
        raw_request_body = cjson.encode(body),
        log_fields     = {},
    }
end

local function make_det(keywords, opts)
    local d = { name="test-det", keywords=keywords or {} }
    if opts then for k,v in pairs(opts) do d[k]=v end end
    return d
end

-- ============================================================================
-- request phase: basic tokenization
-- ============================================================================

describe("custom_pii request phase: keyword detection and tokenization", function()

    it("returns 'pass' when keywords list is empty", function()
        reset()
        local ctx = make_ctx({{role="user",content="secret project"}})
        local r = custom_pii.run(ctx, make_det({}), "request")
        assert.equal("pass", r.verdict)
    end)

    it("returns 'pass' when keyword not present in message", function()
        reset()
        local ctx = make_ctx({{role="user",content="hello world"}})
        local r = custom_pii.run(ctx, make_det({"acme-secret"}), "request")
        assert.equal("pass", r.verdict)
    end)

    it("returns 'scrubbed' and replaces keyword with token", function()
        reset()
        local ctx = make_ctx({{role="user",content="contact acme-corp about the deal"}})
        local r = custom_pii.run(ctx, make_det({"acme-corp"}), "request")
        assert.equal("scrubbed", r.verdict)
        -- The keyword must be replaced in the request body
        local new_content = ctx.request_body.messages[1].content
        assert.is_false(new_content:find("acme%-corp") ~= nil,
            "keyword must be replaced in message content")
        assert.is_true(new_content:find("MYRA%-CUSTOM:") ~= nil,
            "token must contain MYRA-CUSTOM prefix")
    end)

    it("token is stored in ctx.pii_token_map", function()
        reset()
        local ctx = make_ctx({{role="user",content="project omega is secret"}})
        custom_pii.run(ctx, make_det({"omega"}), "request")
        assert.not_nil(ctx.pii_token_map, "pii_token_map must be initialised")
        local found_omega = false
        for _, orig in pairs(ctx.pii_token_map) do
            if orig == "omega" then found_omega = true end
        end
        assert.is_true(found_omega, "token_map must map token → 'omega'")
    end)

    it("same keyword replaced with same token (deduplication across occurrences)", function()
        reset()
        local ctx = make_ctx({{role="user",content="omega omega omega"}})
        custom_pii.run(ctx, make_det({"omega"}), "request")
        -- Count distinct MYRA-CUSTOM tokens in pii_token_map
        local count = 0
        for _ in pairs(ctx.pii_token_map) do count = count + 1 end
        assert.equal(1, count, "one keyword → exactly one token")
    end)

    it("multiple keywords each get distinct tokens", function()
        reset()
        local ctx = make_ctx({{role="user",content="project alpha meets project beta"}})
        custom_pii.run(ctx, make_det({"alpha","beta"}), "request")
        assert.equal(2, (function()
            local c=0; for _ in pairs(ctx.pii_token_map) do c=c+1 end; return c
        end)(), "two keywords → two distinct tokens")
    end)

    it("increments ctx.custom_pii_counter for each new keyword", function()
        reset()
        local ctx = make_ctx({{role="user",content="x y z"}})
        ctx.custom_pii_counter = 5  -- pre-existing counter (shared with pii_protector)
        custom_pii.run(ctx, make_det({"x","y","z"}), "request")
        assert.equal(8, ctx.custom_pii_counter, "counter must reach 8 (5+3)")
    end)

    it("reuses existing pii_token_map (shared with pii_protector)", function()
        reset()
        local ctx = make_ctx({{role="user",content="secret"}})
        -- Pre-populate token map as pii_protector would
        local existing_tok = "[MYRA-REDACT-EMAIL:abc123:1]"
        ctx.pii_token_map = { [existing_tok] = "user@example.com" }
        ctx.custom_pii_counter = 1
        custom_pii.run(ctx, make_det({"secret"}), "request")
        -- Existing entry must still be in the map
        assert.not_nil(ctx.pii_token_map[existing_tok],
            "existing pii_protector tokens must be preserved")
    end)

    it("case-insensitive by default: matches 'ACME' when keyword is 'acme'", function()
        reset()
        local ctx = make_ctx({{role="user",content="Contact ACME Corp"}})
        local r = custom_pii.run(ctx, make_det({"acme"}), "request")
        assert.equal("scrubbed", r.verdict, "case-insensitive match must trigger scrubbing")
    end)

    it("case_sensitive=true: does not match 'ACME' when keyword is 'acme'", function()
        reset()
        local ctx = make_ctx({{role="user",content="Contact ACME Corp"}})
        local r = custom_pii.run(ctx, make_det({"acme"}, {case_sensitive=true}), "request")
        assert.equal("pass", r.verdict, "case-sensitive mode must not match upper-case variant")
    end)

    it("whole_word=true: does not match 'omega' inside 'omegalpha'", function()
        reset()
        local ctx = make_ctx({{role="user",content="omegalpha project"}})
        local r = custom_pii.run(ctx, make_det({"omega"}, {whole_word=true}), "request")
        assert.equal("pass", r.verdict, "whole_word must not match as substring")
    end)

    it("whole_word=false (default): matches 'omega' inside 'omegalpha'", function()
        reset()
        local ctx = make_ctx({{role="user",content="omegalpha project"}})
        local r = custom_pii.run(ctx, make_det({"omega"}), "request")
        assert.equal("scrubbed", r.verdict, "substring match must trigger without whole_word")
    end)

end)

-- ============================================================================
-- collect_texts: various message shapes
-- ============================================================================

describe("custom_pii: collect_texts handles all message content shapes", function()

    it("extracts text from string-content user message", function()
        reset()
        local ctx = make_ctx({{role="user",content="my secret here"}})
        local r = custom_pii.run(ctx, make_det({"secret"}), "request")
        assert.equal("scrubbed", r.verdict)
        assert.is_true(ctx.request_body.messages[1].content:find("MYRA%-CUSTOM:") ~= nil)
    end)

    it("extracts text from content-block array (type=text)", function()
        reset()
        local body = { model="m", messages={{role="user", content={
            {type="text", text="reveal project codename"},
            {type="image_url", image_url={url="http://x.com/img.png"}}
        }}}}
        local ctx = {
            request_id="r", is_compat=true,
            request_body=body, raw_request_body=cjson.encode(body), log_fields={}
        }
        local r = custom_pii.run(ctx, make_det({"codename"}), "request")
        assert.equal("scrubbed", r.verdict)
        -- text block must be modified
        assert.is_true(body.messages[1].content[1].text:find("MYRA%-CUSTOM:") ~= nil)
    end)

    it("skips non-user roles (assistant, system messages)", function()
        reset()
        local ctx = make_ctx({
            {role="system",  content="codename is alpha"},
            {role="assistant", content="I know codename"},
            {role="user", content="hello"},
        })
        local r = custom_pii.run(ctx, make_det({"codename"}), "request")
        -- system and assistant messages are not scanned
        assert.equal("pass", r.verdict,
            "only user messages are scanned; assistant/system must be skipped")
    end)

    it("extracts from top-level 'prompt' field", function()
        reset()
        local body = { model="m", prompt="classify this: codename phoenix" }
        local ctx = { request_id="r", is_compat=true,
                      request_body=body, raw_request_body=cjson.encode(body), log_fields={} }
        local r = custom_pii.run(ctx, make_det({"phoenix"}), "request")
        assert.equal("scrubbed", r.verdict)
        assert.is_true(body.prompt:find("MYRA%-CUSTOM:") ~= nil)
    end)

end)

-- ============================================================================
-- streaming compat: sets pii_force_buffered
-- ============================================================================

describe("custom_pii: streaming compat sets force_buffered", function()

    it("sets pii_force_buffered when is_compat=true and stream=true", function()
        reset()
        local body = { model="m", messages={{role="user",content="secret project"}},
                       stream=true }
        local ctx = { request_id="r", is_compat=true,
                      request_body=body, raw_request_body=cjson.encode(body), log_fields={} }
        custom_pii.run(ctx, make_det({"secret"}), "request")
        assert.is_true(ctx.pii_force_buffered == true,
            "streaming compat with keyword match must set pii_force_buffered")
        assert.is_true(ctx.buffered_needs_sse_reemit == true)
    end)

    it("does not set pii_force_buffered for non-streaming request", function()
        reset()
        local ctx = make_ctx({{role="user",content="secret project"}}, false)
        custom_pii.run(ctx, make_det({"secret"}), "request")
        assert.is_nil(ctx.pii_force_buffered)
    end)

end)

-- ============================================================================
-- response phase: token restoration
-- ============================================================================

describe("custom_pii response phase: token restoration", function()

    it("restores MYRA-CUSTOM token → original keyword in response body", function()
        reset()
        local tok = "[MYRA-CUSTOM:abc123:1]"
        local ctx = {
            request_id="r", log_fields={},
            pii_token_map = { [tok] = "acme-corp" },
            response_body = "I work with " .. tok .. " regularly.",
        }
        local r = custom_pii.run(ctx, make_det({"acme-corp"}), "response")
        assert.equal("scrubbed", r.verdict)
        assert.is_true(ctx.response_body:find("acme%-corp") ~= nil,
            "original keyword must be restored")
        assert.is_false(ctx.response_body:find("MYRA%-CUSTOM:") ~= nil,
            "token placeholder must be gone after restoration")
    end)

    it("ignores non-MYRA-CUSTOM tokens (pii_protector tokens)", function()
        reset()
        local pii_tok    = "[MYRA-REDACT-EMAIL:abc:1]"
        local custom_tok = "[MYRA-CUSTOM:xyz:1]"
        local ctx = {
            request_id="r", log_fields={},
            pii_token_map = {
                [pii_tok]    = "user@example.com",
                [custom_tok] = "codename",
            },
            response_body = "reply with " .. custom_tok .. " and " .. pii_tok,
        }
        custom_pii.run(ctx, make_det({"codename"}), "response")
        -- pii_protector token must remain (only custom_pii processes MYRA-CUSTOM)
        assert.is_true(ctx.response_body:find(pii_tok, 1, true) ~= nil,
            "pii_protector tokens must not be touched by custom_pii restore")
        assert.is_false(ctx.response_body:find(custom_tok, 1, true) ~= nil,
            "custom_pii token must be restored")
    end)

    it("returns 'pass' when response_body is empty", function()
        reset()
        local ctx = { log_fields={}, pii_token_map={}, response_body="" }
        local r = custom_pii.run(ctx, make_det({"keyword"}), "response")
        assert.equal("pass", r.verdict)
    end)

    it("returns 'pass' when pii_token_map is nil", function()
        reset()
        local ctx = { log_fields={}, pii_token_map=nil, response_body="some response" }
        local r = custom_pii.run(ctx, make_det({"keyword"}), "response")
        assert.equal("pass", r.verdict)
    end)

    it("returns 'pass' when token not found in response", function()
        reset()
        local tok = "[MYRA-CUSTOM:abc:1]"
        local ctx = {
            log_fields={},
            pii_token_map = { [tok]="secret" },
            response_body = "no tokens here at all",
        }
        local r = custom_pii.run(ctx, make_det({"secret"}), "response")
        assert.equal("pass", r.verdict)
    end)

end)
