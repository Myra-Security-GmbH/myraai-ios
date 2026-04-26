-- tests/unit/test_provider_gemini.lua — full coverage for providers/gemini.lua
-- Run with: resty tests/runner.lua tests/unit/test_provider_gemini.lua
--
-- Coverage:
--   1. base_url: streaming vs non-streaming suffix, default model
--   2. build_request: role mapping, system_instruction extraction, generationConfig,
--      tools/web_search injection, empty messages
--   3. parse_response: success, multiple parts, token counts, error body, no candidates
--   4. parse_sse_chunk: data parsing, finishReason→done, usageMetadata, non-data lines

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

_G.ngx = {
    log    = function() end,
    exit   = function(c) error(c, 0) end,
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    ERR    = 0, WARN = 1, INFO = 2,
    header = {}, status = 200,
    req    = { get_headers = function() return {} end },
    var    = {}, ctx = {},
}

for _, n in ipairs({"providers.gemini", "utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

local gemini = require("providers.gemini")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_ctx(model, stream, body_override)
    return {
        model      = model,
        request_id = "req-test",
        request_body = body_override or {
            stream   = stream,
            messages = {},
        },
        gateway_config = {},
    }
end

local function decode_request(ctx)
    local raw = gemini.build_request(ctx)
    assert.is_string(raw, "build_request must return a string")
    local t, err = cjson.decode(raw)
    assert.is_nil(err, "build_request must return valid JSON: " .. tostring(err))
    return t
end

-- ---------------------------------------------------------------------------
-- base_url
-- ---------------------------------------------------------------------------

describe("gemini.base_url", function()
    it("non-streaming → :generateContent suffix", function()
        local ctx = make_ctx("gemini-1.5-pro", false)
        local url = gemini.base_url(ctx)
        assert.match("gemini%-1%.5%-pro:generateContent$", url)
        assert.is_false(url:find("streamGenerateContent") ~= nil)
    end)

    it("streaming → :streamGenerateContent?alt=sse suffix", function()
        local ctx = make_ctx("gemini-1.5-flash", true)
        local url = gemini.base_url(ctx)
        assert.match("streamGenerateContent%?alt=sse$", url)
    end)

    it("nil model falls back to gemini-1.5-flash", function()
        local ctx = make_ctx(nil, false)
        local url = gemini.base_url(ctx)
        assert.match("gemini%-1%.5%-flash", url)
    end)

    it("URL starts with https://generativelanguage.googleapis.com", function()
        local url = gemini.base_url(make_ctx("gemini-2.0-flash", false))
        assert.match("^https://generativelanguage%.googleapis%.com", url)
    end)
end)

-- ---------------------------------------------------------------------------
-- build_request
-- ---------------------------------------------------------------------------

describe("gemini.build_request: role mapping", function()
    it("user message → role='user' in contents", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {{ role = "user", content = "Hello" }},
        })
        local body = decode_request(ctx)
        assert.equal(1, #body.contents)
        assert.equal("user", body.contents[1].role)
        assert.equal("Hello", body.contents[1].parts[1].text)
    end)

    it("assistant message → role='model' in contents", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {{ role = "assistant", content = "Hi there" }},
        })
        local body = decode_request(ctx)
        assert.equal("model", body.contents[1].role)
        assert.equal("Hi there", body.contents[1].parts[1].text)
    end)

    it("system message → system_instruction, excluded from contents", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {
                { role = "system",    content = "You are a helper." },
                { role = "user",      content = "What is 2+2?" },
            },
        })
        local body = decode_request(ctx)
        assert.equal(1, #body.contents, "system message must not appear in contents")
        assert.not_nil(body.system_instruction, "system_instruction must be set")
        assert.equal("You are a helper.", body.system_instruction.parts[1].text)
    end)

    it("mixed roles mapped correctly in order", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {
                { role = "user",      content = "Q1" },
                { role = "assistant", content = "A1" },
                { role = "user",      content = "Q2" },
            },
        })
        local body = decode_request(ctx)
        assert.equal(3, #body.contents)
        assert.equal("user",  body.contents[1].role)
        assert.equal("model", body.contents[2].role)
        assert.equal("user",  body.contents[3].role)
    end)

    it("empty messages array → empty contents", function()
        local ctx = make_ctx("gemini-1.5-flash", false, { messages = {} })
        local body = decode_request(ctx)
        assert.equal(0, #body.contents)
    end)
end)

describe("gemini.build_request: generationConfig", function()
    it("max_tokens flows to maxOutputTokens", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {}, max_tokens = 256,
        })
        local body = decode_request(ctx)
        assert.equal(256, body.generationConfig.maxOutputTokens)
    end)

    it("temperature flows through", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {}, temperature = 0.7,
        })
        local body = decode_request(ctx)
        assert.near(0.7, body.generationConfig.temperature, 0.001)
    end)

    it("top_p flows to topP", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {}, top_p = 0.9,
        })
        local body = decode_request(ctx)
        assert.near(0.9, body.generationConfig.topP, 0.001)
    end)
end)

describe("gemini.build_request: tools", function()
    it("web_search tool → googleSearch grounding injected", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {},
            tools    = {{ name = "web_search" }},
        })
        local body = decode_request(ctx)
        assert.not_nil(body.tools, "tools must be set when web_search present")
        assert.equal(1, #body.tools)
        assert.not_nil(body.tools[1].googleSearch)
    end)

    it("non-web_search tool → no googleSearch injected", function()
        local ctx = make_ctx("gemini-1.5-flash", false, {
            messages = {},
            tools    = {{ name = "my_custom_tool" }},
        })
        local body = decode_request(ctx)
        assert.is_nil(body.tools, "unknown tool must not set body.tools")
    end)

    it("nil tools → no tools field in body", function()
        local ctx = make_ctx("gemini-1.5-flash", false, { messages = {}, tools = nil })
        local body = decode_request(ctx)
        assert.is_nil(body.tools)
    end)
end)

-- ---------------------------------------------------------------------------
-- parse_response
-- ---------------------------------------------------------------------------

describe("gemini.parse_response: success", function()
    it("extracts text from candidates[1].content.parts", function()
        local body = cjson.encode({
            candidates = {{
                content = { parts = {{ text = "The sky is blue." }} },
            }},
            usageMetadata = { promptTokenCount = 5, candidatesTokenCount = 8 },
        })
        local r, err = gemini.parse_response(body)
        assert.is_nil(err)
        assert.equal("The sky is blue.", r.content)
        assert.equal(5, r.input_tokens)
        assert.equal(8, r.output_tokens)
    end)

    it("concatenates multiple text parts in order", function()
        local body = cjson.encode({
            candidates = {{
                content = { parts = {
                    { text = "Hello " },
                    { text = "world" },
                }},
            }},
            usageMetadata = {},
        })
        local r = gemini.parse_response(body)
        assert.equal("Hello world", r.content)
    end)

    it("zero token counts when usageMetadata absent", function()
        local body = cjson.encode({
            candidates = {{ content = { parts = {{ text = "ok" }} } }},
        })
        local r = gemini.parse_response(body)
        assert.equal(0, r.input_tokens)
        assert.equal(0, r.output_tokens)
    end)

    it("no candidates → returns empty content without crash", function()
        local body = cjson.encode({ usageMetadata = {} })
        local r, err = gemini.parse_response(body)
        assert.is_nil(err)
        assert.equal("", r.content)
    end)

    it("raw field contains original decoded body", function()
        local src = {
            candidates = {{ content = { parts = {{ text = "x" }} } }},
            usageMetadata = { promptTokenCount = 1, candidatesTokenCount = 1 },
        }
        local r = gemini.parse_response(cjson.encode(src))
        assert.not_nil(r.raw)
        assert.equal(1, r.raw.usageMetadata.promptTokenCount)
    end)
end)

describe("gemini.parse_response: errors", function()
    it("body.error with message → nil + message string", function()
        local body = cjson.encode({
            error = { message = "API key not valid.", code = 400 },
        })
        local r, err = gemini.parse_response(body)
        assert.is_nil(r)
        assert.equal("API key not valid.", err)
    end)

    it("body.error without message → nil + 'provider error'", function()
        local body = cjson.encode({ error = { code = 500 } })
        local r, err = gemini.parse_response(body)
        assert.is_nil(r)
        assert.equal("provider error", err)
    end)

    it("nil input → result with empty content (json.decode(nil) returns {})", function()
        -- cjson.decode(nil) returns an empty table, not nil.
        -- parse_response handles this gracefully: no candidates → empty content.
        local r, err = gemini.parse_response(nil)
        assert.is_nil(err)
        assert.not_nil(r)
        assert.equal("", r.content)
    end)

    it("invalid JSON string → nil + error", function()
        local r, err = gemini.parse_response("not json {{{")
        assert.is_nil(r)
        assert.not_nil(err)
    end)
end)

-- ---------------------------------------------------------------------------
-- parse_sse_chunk
-- ---------------------------------------------------------------------------

describe("gemini.parse_sse_chunk: data line parsing", function()
    it("parses 'data: {...}' and returns delta", function()
        local chunk = { candidates = {{
            content = { parts = {{ text = "Hello" }} },
        }}}
        local line = "data: " .. cjson.encode(chunk)
        local r = gemini.parse_sse_chunk(line)
        assert.not_nil(r)
        assert.equal("Hello", r.delta)
    end)

    it("finishReason='STOP' → done=true", function()
        local chunk = { candidates = {{
            content      = { parts = {{ text = "" }} },
            finishReason = "STOP",
        }}}
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.is_true(r.done)
    end)

    it("finishReason='' (empty string) → done=false", function()
        local chunk = { candidates = {{
            content      = { parts = {{ text = "x" }} },
            finishReason = "",
        }}}
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.is_false(r.done)
    end)

    it("no finishReason field → done=false", function()
        local chunk = { candidates = {{
            content = { parts = {{ text = "mid-stream" }} },
        }}}
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.is_false(r.done)
    end)

    it("usageMetadata → input_tokens and output_tokens populated", function()
        local chunk = {
            candidates    = {{ content = { parts = {} } }},
            usageMetadata = { promptTokenCount = 10, candidatesTokenCount = 20 },
        }
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.not_nil(r)
        assert.equal(10, r.input_tokens)
        assert.equal(20, r.output_tokens)
    end)

    it("no usageMetadata → input_tokens and output_tokens are nil", function()
        local chunk = { candidates = {{ content = { parts = {{ text = "x" }} } }} }
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.is_nil(r.input_tokens)
        assert.is_nil(r.output_tokens)
    end)

    it("multiple text parts concatenated in delta", function()
        local chunk = { candidates = {{
            content = { parts = {{ text = "foo " }, { text = "bar" }} },
        }}}
        local r = gemini.parse_sse_chunk("data: " .. cjson.encode(chunk))
        assert.equal("foo bar", r.delta)
    end)
end)

describe("gemini.parse_sse_chunk: non-data lines", function()
    it("line without 'data:' prefix → nil", function()
        assert.is_nil(gemini.parse_sse_chunk("event: ping"))
        assert.is_nil(gemini.parse_sse_chunk(""))
        assert.is_nil(gemini.parse_sse_chunk(": heartbeat"))
    end)

    it("'data: [DONE]' (non-JSON) → nil", function()
        assert.is_nil(gemini.parse_sse_chunk("data: [DONE]"))
    end)

    it("malformed JSON in data field → nil", function()
        assert.is_nil(gemini.parse_sse_chunk("data: {bad json"))
    end)
end)
