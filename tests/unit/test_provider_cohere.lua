-- tests/unit/test_provider_cohere.lua
-- Run with: busted tests/unit/test_provider_cohere.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = { http_x_request_id = "" },
    req    = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

clear({"providers.cohere","utils.json"})
local cohere = require("providers.cohere")

-- ── base_url ───────────────────────────────────────────────────────────────

describe("providers.cohere — base_url", function()
    it("always returns /v2/chat endpoint", function()
        local ctx = { gateway_config = {}, request_id = "r1", model = "command-r-plus",
                      request_body = {} }
        assert.equal("https://api.cohere.com/v2/chat", cohere.base_url(ctx))
    end)
end)

-- ── build_headers ──────────────────────────────────────────────────────────

describe("providers.cohere — build_headers", function()
    local ctx = { request_id = "req-1", gateway_config = {} }

    it("sets Bearer Authorization", function()
        local h = cohere.build_headers(ctx, "co-key")
        assert.equal("Bearer co-key",    h["Authorization"])
    end)

    it("sets Content-Type application/json", function()
        local h = cohere.build_headers(ctx, "co-key")
        assert.equal("application/json", h["Content-Type"])
    end)
end)

-- ── build_request ──────────────────────────────────────────────────────────

describe("providers.cohere — build_request", function()
    local cjson = require("cjson.safe")

    local function decode(ctx)
        local body_str = cohere.build_request(ctx)
        return cjson.decode(body_str)
    end

    it("includes model and messages", function()
        local ctx = {
            model        = "command-r-plus",
            request_body = {
                messages = {
                    { role = "user", content = "Hello" },
                },
            },
        }
        local b = decode(ctx)
        assert.equal("command-r-plus", b.model)
        assert.equal(1, #b.messages)
        assert.equal("user",  b.messages[1].role)
        assert.equal("Hello", b.messages[1].content)
    end)

    it("preserves system messages", function()
        local ctx = {
            model        = "command-r",
            request_body = {
                messages = {
                    { role = "system", content = "You are helpful." },
                    { role = "user",   content = "Hi" },
                },
            },
        }
        local b = decode(ctx)
        assert.equal(2, #b.messages)
        assert.equal("system", b.messages[1].role)
    end)

    it("sets stream=false when not streaming", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {} },
        }
        local b = decode(ctx)
        assert.is_false(b.stream)
    end)

    it("sets stream=true when streaming", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, stream = true },
        }
        local b = decode(ctx)
        assert.is_true(b.stream)
    end)

    it("forwards max_tokens", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, max_tokens = 256 },
        }
        local b = decode(ctx)
        assert.equal(256, b.max_tokens)
    end)

    it("forwards temperature", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, temperature = 0.7 },
        }
        local b = decode(ctx)
        assert.is_true(math.abs(b.temperature - 0.7) < 1e-9)
    end)

    it("maps top_p to p", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, top_p = 0.9 },
        }
        local b = decode(ctx)
        assert.is_true(math.abs(b.p - 0.9) < 1e-9)
    end)

    it("converts string stop to stop_sequences array", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, stop = "END" },
        }
        local b = decode(ctx)
        assert.equal(1,     #b.stop_sequences)
        assert.equal("END", b.stop_sequences[1])
    end)

    it("preserves array stop as stop_sequences", function()
        local ctx = {
            model        = "command-r",
            request_body = { messages = {}, stop = { "END", "STOP" } },
        }
        local b = decode(ctx)
        assert.equal(2, #b.stop_sequences)
    end)
end)

-- ── parse_response ─────────────────────────────────────────────────────────

describe("providers.cohere — parse_response", function()
    it("extracts text content and billed token counts", function()
        local body = [[{
            "id": "gen-1",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "Hello world"}]
            },
            "usage": {
                "billed_units": {"input_tokens": 10, "output_tokens": 7}
            }
        }]]
        local r, err = cohere.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello world", r.content)
        assert.equal(10,            r.input_tokens)
        assert.equal(7,             r.output_tokens)
    end)

    it("concatenates multiple text blocks", function()
        local body = [[{
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "foo"},
                    {"type": "text", "text": "bar"}
                ]
            },
            "usage": {"billed_units": {"input_tokens": 1, "output_tokens": 2}}
        }]]
        local r = cohere.parse_response(body)
        assert.equal("foobar", r.content)
    end)

    it("returns error for string message field", function()
        local body = [[{"message": "invalid api key"}]]
        local r, err = cohere.parse_response(body)
        assert.is_nil(r)
        assert.equal("invalid api key", err)
    end)

    it("returns error for json decode failure", function()
        local r, err = cohere.parse_response("not json{{{")
        assert.is_nil(r)
        assert.equal("json decode failed", err)
    end)

    it("defaults tokens to 0 when usage absent", function()
        local body = [[{"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}]]
        local r, err = cohere.parse_response(body)
        assert.is_nil(err)
        assert.equal(0, r.input_tokens)
        assert.equal(0, r.output_tokens)
    end)
end)

-- ── parse_sse_chunk ────────────────────────────────────────────────────────

describe("providers.cohere — parse_sse_chunk", function()
    it("returns nil for non-data lines", function()
        assert.is_nil(cohere.parse_sse_chunk(""))
        assert.is_nil(cohere.parse_sse_chunk(": keep-alive"))
        assert.is_nil(cohere.parse_sse_chunk("event: ping"))
    end)

    it("extracts text from content-delta event", function()
        local line = [[data: {"type":"content-delta","index":0,"delta":{"type":"text-delta","text":"Hello"}}]]
        local r = cohere.parse_sse_chunk(line)
        assert.not_nil(r)
        assert.equal("Hello", r.delta)
        assert.is_false(r.done)
    end)

    it("returns empty delta for non-text-delta content events", function()
        local line = [[data: {"type":"content-start","index":0,"delta":{"type":"text-start","text":""}}]]
        local r = cohere.parse_sse_chunk(line)
        assert.not_nil(r)
        assert.equal("", r.delta)
        assert.is_false(r.done)
    end)

    it("returns done=true and token counts on message-end", function()
        local line = [[data: {"type":"message-end","delta":{"finish_reason":"COMPLETE",
            "usage":{"billed_units":{"input_tokens":5,"output_tokens":3}}}}]]
        local r = cohere.parse_sse_chunk(line)
        assert.not_nil(r)
        assert.is_true(r.done)
        assert.equal(5, r.input_tokens)
        assert.equal(3, r.output_tokens)
    end)

    it("returns nil tokens on non-terminal chunks", function()
        local line = [[data: {"type":"content-delta","index":0,"delta":{"type":"text-delta","text":"x"}}]]
        local r = cohere.parse_sse_chunk(line)
        assert.is_nil(r.input_tokens)
        assert.is_nil(r.output_tokens)
    end)

    it("returns nil for malformed JSON data", function()
        local r = cohere.parse_sse_chunk("data: {bad json")
        assert.is_nil(r)
    end)
end)
