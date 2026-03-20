-- tests/integration/test_mock_provider.lua
-- Verify mock provider itself behaves correctly before running gateway tests.
-- Run: busted tests/integration/test_mock_provider.lua
-- Requires: mock provider running (tests/mock_provider/start.sh)

local h = require("tests.integration.helpers")

describe("mock provider", function()

    before_each(function()
        h.mock_reset()
    end)

    -- -----------------------------------------------------------------------
    -- Connectivity
    -- -----------------------------------------------------------------------
    it("responds on 127.0.0.1:19000", function()
        local r = h.request({ url = "http://127.0.0.1:19000/v1/chat/completions",
                               method = "POST",
                               headers = { ["Content-Type"] = "application/json" },
                               body = '{"model":"gpt-4o-mini","messages":[]}' })
        assert.equal(200, r.status)
    end)

    -- -----------------------------------------------------------------------
    -- Normal responses
    -- -----------------------------------------------------------------------
    it("returns OpenAI chat completion JSON", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}',
        })
        assert.equal(200, r.status)
        assert.equal("application/json", r.headers["content-type"])

        local body = require("cjson.safe").decode(r.body)
        assert.not_nil(body)
        assert.not_nil(body.choices)
        assert.not_nil(body.usage)
        assert.equal(12, body.usage.prompt_tokens)
    end)

    it("returns Anthropic messages JSON for /v1/messages", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/messages",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"claude-haiku-4-5-20251001","messages":[],"max_tokens":100}',
        })
        assert.equal(200, r.status)
        local body = require("cjson.safe").decode(r.body)
        assert.equal("message", body.type)
        assert.not_nil(body.content)
        assert.equal(12, body.usage.input_tokens)
    end)

    -- -----------------------------------------------------------------------
    -- Error simulation via X-Mock-Status
    -- -----------------------------------------------------------------------
    it("returns forced HTTP status via X-Mock-Status header", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json",
                        ["X-Mock-Status"] = "500" },
            body    = '{"model":"gpt-4o-mini","messages":[]}',
        })
        assert.equal(500, r.status)
        local body = require("cjson.safe").decode(r.body)
        assert.not_nil(body.error)
    end)

    it("returns 429 for model=x-mock-ratelimit", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"x-mock-ratelimit","messages":[]}',
        })
        assert.equal(429, r.status)
    end)

    it("returns 500 for model=x-mock-error", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"x-mock-error","messages":[]}',
        })
        assert.equal(500, r.status)
    end)

    -- -----------------------------------------------------------------------
    -- Streaming
    -- -----------------------------------------------------------------------
    it("returns SSE when stream=true", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"gpt-4o-mini","stream":true,"messages":[]}',
        })
        assert.equal(200, r.status)
        assert.equal("text/event-stream", r.headers["content-type"])
        assert.not_nil(r.body:find("data:"))
        assert.not_nil(r.body:find("%[DONE%]"))
    end)

    it("returns SSE for model=x-mock-stream", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"x-mock-stream","messages":[]}',
        })
        assert.equal(200, r.status)
        assert.equal("text/event-stream", r.headers["content-type"])
    end)

    it("returns SSE for X-Mock-Scenario: streaming", function()
        local r = h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json",
                        ["X-Mock-Scenario"] = "streaming" },
            body    = '{"model":"gpt-4o-mini","messages":[]}',
        })
        assert.equal(200, r.status)
        assert.equal("text/event-stream", r.headers["content-type"])
    end)

    -- -----------------------------------------------------------------------
    -- Call tracking
    -- -----------------------------------------------------------------------
    it("tracks call count via /mock/calls", function()
        -- Make 3 calls
        for _ = 1, 3 do
            h.request({
                url     = "http://127.0.0.1:19000/v1/chat/completions",
                method  = "POST",
                headers = { ["Content-Type"] = "application/json" },
                body    = '{"model":"gpt-4o-mini","messages":[]}',
            })
        end
        assert.equal(3, h.mock_calls())
    end)

    it("returns last request body via /mock/last-request", function()
        h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body    = '{"model":"sentinel-model","messages":[]}',
        })
        local last = h.mock_last_request()
        assert.not_nil(last)
        assert.equal("sentinel-model", last.model)
    end)

    it("/mock/reset clears counters", function()
        h.request({
            url    = "http://127.0.0.1:19000/v1/chat/completions",
            method = "POST",
            headers = { ["Content-Type"] = "application/json" },
            body   = '{"model":"gpt-4o-mini","messages":[]}',
        })
        assert.equal(1, h.mock_calls())
        h.mock_reset()
        assert.equal(0, h.mock_calls())
    end)

    -- -----------------------------------------------------------------------
    -- Delay
    -- -----------------------------------------------------------------------
    it("respects X-Mock-Delay header", function()
        -- Use date +%s%3N for wall-clock milliseconds (os.clock() is CPU time)
        local t0 = tonumber(io.popen("date +%s%3N"):read("*l")) or 0
        h.request({
            url     = "http://127.0.0.1:19000/v1/chat/completions",
            method  = "POST",
            headers = { ["Content-Type"] = "application/json",
                        ["X-Mock-Delay"] = "200" },
            body    = '{"model":"gpt-4o-mini","messages":[]}',
        })
        local t1 = tonumber(io.popen("date +%s%3N"):read("*l")) or 0
        local elapsed_ms = t1 - t0
        assert.is_true(elapsed_ms >= 190, "expected >= 190ms delay, got " .. elapsed_ms)
    end)

end)
