-- tests/unit/test_guardrails_presidio.lua — guardrails/presidio.lua
-- Run with: resty tests/runner.lua tests/unit/test_guardrails_presidio.lua
--
-- Coverage:
--   1. call_analyzer: sends correct payload (text, language, entities, score_threshold)
--   2. apply_entity_thresholds: HIGH_FP entities (PERSON/LOCATION/DATE_TIME/ORG) need elevated confidence
--   3. apply_entity_thresholds: per-entity config overrides HIGH_FP defaults
--   4. effective_global_threshold: uses minimum of per-entity thresholds as global floor
--   5. action=block: returns block verdict with entity_type list
--   6. action=flag (default): returns flagged verdict
--   7. action=scrub: calls anonymizer, returns scrubbed verdict with anonymized body
--   8. HTTP error from analyzer → error verdict
--   9. empty text → pass immediately
--  10. no entities after thresholding → pass
--  11. anonymizer error → error verdict

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _log_buf = {}
_G.ngx = {
    log  = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    now  = function() return 1700000000.0 end,
    ERR  = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"guardrails.presidio","utils.json","utils.http","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end
package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

-- HTTP mock: controllable per-call
local _http_calls = {}
local _http_responses = {}   -- queue: each call pops front

local function queue_http(status, body, err)
    _http_responses[#_http_responses+1] = { status=status, body=body, err=err }
end

package.preload["utils.http"] = function()
    return {
        request = function(opts)
            _http_calls[#_http_calls+1] = { url=opts.url, body=opts.body, method=opts.method }
            local r = table.remove(_http_responses, 1)
            if not r then return 200, {}, "[]", nil end
            return r.status, {}, r.body, r.err
        end,
    }
end

local presidio = require("guardrails.presidio")

local function reset()
    _log_buf       = {}
    _http_calls    = {}
    _http_responses = {}
end

local function make_ctx(body_text, is_response)
    if is_response then
        return { log_fields={}, tenant_id="tn-1",
                 response_body = body_text or "contains John Smith email user@x.com" }
    end
    return { log_fields={}, tenant_id="tn-1",
             raw_request_body = body_text or "my email is user@example.com call me" }
end

local function make_det(action, opts)
    local d = { name="test-presidio", action=action or "block" }
    if opts then for k,v in pairs(opts) do d[k]=v end end
    return d
end

-- Helper: make a single entity result
local function entity(etype, score, s, e)
    return { entity_type=etype, score=score or 0.9, start=s or 0, ["end"]=e or 10 }
end

-- ============================================================================
-- Analyzer call: request payload
-- ============================================================================

describe("presidio: analyzer HTTP request format", function()

    it("sends POST to /analyze endpoint", function()
        reset()
        queue_http(200, "[]")
        local ctx = make_ctx()
        presidio.run(ctx, make_det("flag"), "request")
        assert.equal(1, #_http_calls)
        assert.is_true(_http_calls[1].url:find("/analyze") ~= nil,
            "must POST to /analyze: " .. (_http_calls[1].url or ""))
        assert.equal("POST", _http_calls[1].method)
    end)

    it("payload includes text and language fields", function()
        reset()
        queue_http(200, "[]")
        local ctx = make_ctx("some text here")
        presidio.run(ctx, make_det("flag", {language="en"}), "request")
        local payload = cjson.decode(_http_calls[1].body)
        assert.not_nil(payload)
        assert.equal("some text here", payload.text)
        assert.equal("en", payload.language)
    end)

    it("uses detector.url for analyzer endpoint", function()
        reset()
        queue_http(200, "[]")
        local ctx = make_ctx()
        presidio.run(ctx, make_det("flag", {url="http://custom-presidio:5002"}), "request")
        assert.is_true(_http_calls[1].url:find("custom%-presidio:5002") ~= nil)
    end)

end)

-- ============================================================================
-- Score thresholds
-- ============================================================================

describe("presidio: score threshold filtering", function()

    it("PERSON entity at 0.8 is filtered out by HIGH_FP default (0.9 required)", function()
        reset()
        -- Analyzer returns a PERSON entity at score=0.8
        queue_http(200, cjson.encode({ entity(("PERSON"), 0.8) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        -- Default PERSON threshold is 0.9; 0.8 < 0.9 → filtered → pass
        assert.equal("pass", r.verdict,
            "PERSON at 0.8 must be filtered by HIGH_FP threshold (0.9)")
    end)

    it("PERSON entity at 0.95 passes HIGH_FP default threshold", function()
        reset()
        queue_http(200, cjson.encode({ entity("PERSON", 0.95) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("block", r.verdict, "PERSON at 0.95 must exceed HIGH_FP 0.9 threshold")
    end)

    it("LOCATION entity at 0.85 is filtered (HIGH_FP threshold 0.9)", function()
        reset()
        queue_http(200, cjson.encode({ entity("LOCATION", 0.85) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("flag"), "request")
        assert.equal("pass", r.verdict, "LOCATION at 0.85 must be filtered (< 0.9)")
    end)

    it("per-entity config overrides HIGH_FP default: PERSON at 0.7 with config threshold 0.6 → block", function()
        reset()
        queue_http(200, cjson.encode({ entity("PERSON", 0.7) }))
        local ctx = make_ctx()
        -- Caller explicitly lowers PERSON threshold to 0.6
        local r = presidio.run(ctx, make_det("block", {
            entity_score_thresholds = { PERSON = 0.6 }
        }), "request")
        assert.equal("block", r.verdict,
            "explicit PERSON threshold 0.6 must allow 0.7 score to pass through")
    end)

    it("EMAIL_ADDRESS (not HIGH_FP) at 0.75 is kept (global threshold 0.7 default)", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.75) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("block", r.verdict,
            "EMAIL_ADDRESS is not HIGH_FP; 0.75 >= default 0.7 threshold")
    end)

end)

-- ============================================================================
-- Verdict routing
-- ============================================================================

describe("presidio: verdict routing by action", function()

    it("action=block returns 'block' verdict with entity_type string", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("block", r.verdict)
        assert.not_nil(r.pattern)
        assert.is_true(r.pattern:find("EMAIL_ADDRESS") ~= nil)
    end)

    it("action=flag returns 'flagged' verdict (not block)", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("flag"), "request")
        assert.equal("flagged", r.verdict)
    end)

    it("action=scrub calls anonymizer and returns 'scrubbed' verdict", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        queue_http(200, cjson.encode({ text = "my email is <EMAIL_ADDRESS>" }))
        local ctx = make_ctx("my email is user@example.com")
        local r = presidio.run(ctx, make_det("scrub"), "request")
        assert.equal("scrubbed", r.verdict)
        assert.equal(2, #_http_calls, "scrub must call both analyzer and anonymizer")
        assert.is_true(_http_calls[2].url:find("/anonymize") ~= nil)
        -- response body updated
        assert.equal("my email is <EMAIL_ADDRESS>", ctx.raw_request_body)
    end)

end)

-- ============================================================================
-- Error paths
-- ============================================================================

describe("presidio: error paths", function()

    it("returns 'pass' when text is empty", function()
        reset()
        local ctx = make_ctx("")
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("pass", r.verdict)
        assert.equal(0, #_http_calls, "analyzer must not be called for empty text")
    end)

    it("returns 'error' verdict on analyzer HTTP failure", function()
        reset()
        queue_http(nil, nil, "connection refused")
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("error", r.verdict)
        assert.equal("analyzer", r.stage)
        assert.not_nil(r.message)
    end)

    it("returns 'error' verdict on analyzer non-200 response", function()
        reset()
        queue_http(503, "service unavailable", nil)
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("error", r.verdict)
    end)

    it("returns 'error' on anonymizer failure when action=scrub", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        queue_http(nil, nil, "anonymizer down")
        local ctx = make_ctx("email user@example.com")
        local r = presidio.run(ctx, make_det("scrub"), "request")
        assert.equal("error", r.verdict)
        assert.equal("anonymizer", r.stage)
    end)

    it("returns 'pass' when no entities after threshold filtering", function()
        reset()
        -- Analyzer returns a PERSON entity but below HIGH_FP threshold
        queue_http(200, cjson.encode({ entity("PERSON", 0.5) }))
        local ctx = make_ctx()
        local r = presidio.run(ctx, make_det("block"), "request")
        assert.equal("pass", r.verdict, "no entities above threshold → pass")
    end)

end)

-- ============================================================================
-- Response phase
-- ============================================================================

describe("presidio: response phase", function()

    it("scans response_body instead of raw_request_body", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        local ctx = make_ctx("response text with user@example.com", true)
        presidio.run(ctx, make_det("flag"), "response")
        local payload = cjson.decode(_http_calls[1].body)
        assert.equal("response text with user@example.com", payload.text)
    end)

    it("action=scrub updates response_body with anonymized text", function()
        reset()
        queue_http(200, cjson.encode({ entity("EMAIL_ADDRESS", 0.9) }))
        queue_http(200, cjson.encode({ text = "response with <EMAIL_ADDRESS>" }))
        local ctx = make_ctx("response with user@example.com", true)
        presidio.run(ctx, make_det("scrub"), "response")
        assert.equal("response with <EMAIL_ADDRESS>", ctx.response_body)
    end)

end)
