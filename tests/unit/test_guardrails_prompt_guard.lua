-- tests/unit/test_guardrails_prompt_guard.lua — guardrails/prompt_guard.lua
-- Run with: resty tests/runner.lua tests/unit/test_guardrails_prompt_guard.lua
--
-- Coverage:
--   1. extract_request_messages: last user message, content-block array, prompt field
--   2. extract_response_messages: OpenAI choices format, Anthropic content format
--   3. classify: sends correct payload (model, messages, max_tokens, temperature=0)
--   4. M.run safe response → pass
--   5. M.run unsafe → block (default action)
--   6. M.run unsafe + action=flag → flagged (not block)
--   7. M.run category filter: blocks only when categories match whitelist
--   8. M.run category filter: passes when detected categories outside whitelist
--   9. HTTP error → error verdict
--  10. No messages → pass
--  11. Response phase: uses response_body
--  12. context_prompt prepended to message text

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _log_buf = {}
_G.ngx = {
    log  = function(_, ...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts+1] = tostring(select(i, ...)) end
        _log_buf[#_log_buf+1] = table.concat(parts)
    end,
    now  = function() return 1700000000.0 end,
    ERR  = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"guardrails.prompt_guard","utils.json","utils.http",
                    "utils.request","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end
package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end
package.preload["utils.request"] = function()
    return { read_body=function() return nil end }
end

local _http_calls     = {}
local _http_responses = {}

local function queue_http(status, body, err)
    _http_responses[#_http_responses+1] = {status=status, body=body, err=err}
end

local function pg_classify_response(verdict, categories)
    return cjson.encode({
        choices = {{ message = { content = verdict .. (categories and "\n"..categories or "") } }}
    })
end

package.preload["utils.http"] = function()
    return {
        request = function(opts)
            _http_calls[#_http_calls+1] = { url=opts.url, body=opts.body }
            local r = table.remove(_http_responses, 1)
            if not r then return 200, {}, pg_classify_response("safe"), nil end
            return r.status, {}, r.body, r.err
        end,
    }
end

local pg = require("guardrails.prompt_guard")

local function reset()
    _log_buf       = {}
    _http_calls    = {}
    _http_responses = {}
end

local function make_req_ctx(messages)
    local body = { model="gpt-4o",
                   messages=messages or {{role="user",content="hello"}} }
    return { log_fields={}, tenant_id="tn-1",
             request_body=body, raw_request_body=cjson.encode(body) }
end

local function make_det(action, opts)
    local d = { name="pg-det", action=action or "block" }
    if opts then for k,v in pairs(opts) do d[k]=v end end
    return d
end

-- ============================================================================
-- Classifier HTTP request format
-- ============================================================================

describe("prompt_guard: classifier HTTP request", function()

    it("sends POST to /v1/chat/completions", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        pg.run(make_req_ctx(), make_det(), "request")
        assert.equal(1, #_http_calls)
        assert.is_true(_http_calls[1].url:find("/v1/chat/completions") ~= nil)
    end)

    it("payload uses model=llama-guard-3-8b, temperature=0, max_tokens=20", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        pg.run(make_req_ctx(), make_det(), "request")
        local p = cjson.decode(_http_calls[1].body)
        assert.equal("llama-guard-3-8b", p.model)
        assert.equal(0,  p.temperature)
        assert.equal(20, p.max_tokens)
    end)

    it("sends only the last user message (not full history)", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        local ctx = make_req_ctx({
            {role="user",      content="first message"},
            {role="assistant", content="first reply"},
            {role="user",      content="second message"},
        })
        pg.run(ctx, make_det(), "request")
        local p = cjson.decode(_http_calls[1].body)
        assert.equal(1, #p.messages, "only last user message must be sent")
        assert.equal("user", p.messages[1].role)
        assert.is_true(p.messages[1].content:find("second message") ~= nil)
        assert.is_false(p.messages[1].content:find("first message") ~= nil,
            "earlier messages must be excluded")
    end)

    it("uses detector.url override", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        pg.run(make_req_ctx(), make_det("block", {url="http://pg-custom:8083"}), "request")
        assert.is_true(_http_calls[1].url:find("pg%-custom:8083") ~= nil)
    end)

    it("context_prompt is prepended to user message content", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        pg.run(make_req_ctx(), make_det("block", {context_prompt="medical gateway"}), "request")
        local p = cjson.decode(_http_calls[1].body)
        assert.is_true(p.messages[1].content:find("medical gateway") ~= nil,
            "context_prompt must be prepended")
    end)

end)

-- ============================================================================
-- Safe vs. unsafe verdicts
-- ============================================================================

describe("prompt_guard: safe/unsafe/error routing", function()

    it("safe response → 'pass' verdict", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        local r = pg.run(make_req_ctx(), make_det(), "request")
        assert.equal("pass", r.verdict)
    end)

    it("unsafe response → 'block' verdict (default action)", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S2,S10"))
        local r = pg.run(make_req_ctx(), make_det("block"), "request")
        assert.equal("block", r.verdict)
        assert.not_nil(r.pattern)
    end)

    it("unsafe response + action=flag → 'flagged' verdict (not block)", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S1"))
        local r = pg.run(make_req_ctx(), make_det("flag"), "request")
        assert.equal("flagged", r.verdict)
    end)

    it("HTTP error → 'error' verdict with stage='classify'", function()
        reset()
        queue_http(nil, nil, "connection refused")
        local r = pg.run(make_req_ctx(), make_det(), "request")
        assert.equal("error", r.verdict)
        assert.equal("classify", r.stage)
    end)

    it("non-200 HTTP → 'error' verdict", function()
        reset()
        queue_http(503, "unavailable", nil)
        local r = pg.run(make_req_ctx(), make_det(), "request")
        assert.equal("error", r.verdict)
    end)

    it("no user message in body → 'pass' without calling classifier", function()
        reset()
        local body = { model="m", messages={{role="assistant",content="hello"}} }
        local ctx = { log_fields={}, request_body=body, raw_request_body=cjson.encode(body) }
        local r = pg.run(ctx, make_det(), "request")
        assert.equal("pass", r.verdict)
        assert.equal(0, #_http_calls, "classifier must not be called when no user message")
    end)

end)

-- ============================================================================
-- Category filter
-- ============================================================================

describe("prompt_guard: category filter (detector.categories whitelist)", function()

    it("blocks when detected category is in the whitelist", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S2"))
        local r = pg.run(make_req_ctx(), make_det("block", {categories={"S2","S10"}}), "request")
        assert.equal("block", r.verdict, "S2 is in whitelist → must block")
        assert.equal("S2", r.pattern)
    end)

    it("passes when detected category is outside the whitelist", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S3"))
        local r = pg.run(make_req_ctx(), make_det("block", {categories={"S1","S2"}}), "request")
        assert.equal("pass", r.verdict,
            "S3 not in whitelist → must pass (category filtered out)")
    end)

    it("no filter (empty categories): all unsafe categories block", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S99"))
        local r = pg.run(make_req_ctx(), make_det("block", {categories={}}), "request")
        -- Empty categories list = no filter → all categories cause block
        assert.equal("block", r.verdict)
    end)

    it("multiple categories: intersection is correct", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S1,S5,S9"))
        local r = pg.run(make_req_ctx(),
            make_det("block", {categories={"S5","S10"}}), "request")
        assert.equal("block", r.verdict, "S5 intersects with whitelist → block")
        assert.is_true(r.pattern:find("S5") ~= nil, "pattern should contain S5")
    end)

end)

-- ============================================================================
-- Response phase
-- ============================================================================

describe("prompt_guard: response phase", function()

    it("classifies response_body (OpenAI choices format)", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        local ctx = {
            log_fields    = {},
            tenant_id     = "tn-1",
            response_body = cjson.encode({
                choices = {{ message = { role="assistant", content="the answer" } }},
            }),
        }
        pg.run(ctx, make_det(), "response")
        local payload = cjson.decode(_http_calls[1].body)
        assert.equal("assistant", payload.messages[1].role)
        assert.is_true(payload.messages[1].content:find("the answer") ~= nil)
    end)

    it("classifies response_body (Anthropic content format)", function()
        reset()
        queue_http(200, pg_classify_response("safe"))
        local ctx = {
            log_fields    = {},
            response_body = cjson.encode({
                content = {{ type="text", text="anthropic answer" }},
            }),
        }
        pg.run(ctx, make_det(), "response")
        local payload = cjson.decode(_http_calls[1].body)
        assert.is_true(payload.messages[1].content:find("anthropic answer") ~= nil)
    end)

    it("unsafe response in response phase → block", function()
        reset()
        queue_http(200, pg_classify_response("unsafe", "S2"))
        local ctx = {
            log_fields    = {},
            response_body = cjson.encode({ choices={{message={content="bad content"}}} }),
        }
        local r = pg.run(ctx, make_det("block"), "response")
        assert.equal("block", r.verdict)
    end)

    it("empty response_body → pass without calling classifier", function()
        reset()
        local ctx = { log_fields={}, response_body="" }
        local r = pg.run(ctx, make_det(), "response")
        assert.equal("pass", r.verdict)
        assert.equal(0, #_http_calls)
    end)

end)
