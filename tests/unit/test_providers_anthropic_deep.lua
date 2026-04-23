-- tests/unit/test_providers_anthropic_deep.lua — deep coverage for providers/anthropic.lua
-- Run with: resty tests/runner.lua tests/unit/test_providers_anthropic_deep.lua
--
-- Coverage (builds on test_providers_tier1.lua which tests base contracts):
--   1. build_request compat path: OpenAI → Anthropic format conversion
--   2. build_request compat: system prompt extraction
--   3. parse_response: cache_deletion_tokens extraction
--   4. parse_sse_chunk: message_start with cache_deletion_input_tokens
--   5. parse_sse_chunk: text content_block_delta accumulation
--   6. parse_sse_chunk: message_stop returns done=true
--   7. parse_sse_chunk: stop_reason from message_delta

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

local _req_headers = {}
local _log_buf     = {}

_G.ngx = {
    encode_base64 = _real_encode_base64,
    decode_base64 = _real_decode_base64,
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) error(c, 0) end,
    print  = function() end,
    status = 200,
    header = {},
    req    = { get_headers = function() return _req_headers end },
    var    = {},
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
}

for _, n in ipairs({"providers.anthropic","utils.json","core.app_config","state","utils.uuid","utils.trace"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return {
        defaults = {
            prompt_caching     = { enabled = false },
            context_compaction = { enabled = false },
        }
    }
end

package.preload["state"] = function()
    local c = {}
    return { config_get=function(k) return c[k] end, config_set=function(k,v) c[k]=v end }
end

package.preload["utils.trace"] = function()
    return { step=function() end, done=function() end }
end

-- Load real utils.json (needed for encode/decode in build_request/parse_response)
package.preload["utils.json"] = function()
    local j = {}
    j.encode = cjson.encode
    j.decode = cjson.decode
    j.null   = cjson.null
    -- sanitize_surrogates: pass-through in tests
    j.sanitize_surrogates = function(s) return s end
    return j
end

local anthropic = require("providers.anthropic")

local function reset()
    _req_headers = {}
    _log_buf     = {}
    _G.ngx.ctx   = {}
end

-- ============================================================================
-- build_request: compat path (OpenAI → Anthropic)
-- ============================================================================

describe("anthropic.build_request: compat path", function()

    local function make_compat_ctx(messages, system_msg, model)
        local msgs = messages or {{ role="user", content="hello" }}
        if system_msg then
            table.insert(msgs, 1, { role="system", content=system_msg })
        end
        return {
            is_compat      = true,
            gateway_config = { prompt_caching={enabled=false}, context_compaction={enabled=false} },
            request_body   = {
                model    = model or "claude-3-5-sonnet-20241022",
                messages = msgs,
                max_tokens = 1024,
            },
            model = model or "claude-3-5-sonnet-20241022",
        }
    end

    it("converts OpenAI user message to Anthropic messages array", function()
        reset()
        local ctx = make_compat_ctx({{ role="user", content="hi there" }})
        local out_str = anthropic.build_request(ctx)
        assert.not_nil(out_str)
        local out = cjson.decode(out_str)
        assert.not_nil(out.messages)
        assert.equal(1, #out.messages)
        assert.equal("user", out.messages[1].role)
    end)

    it("extracts system message into top-level 'system' field", function()
        reset()
        local ctx = make_compat_ctx({{ role="user", content="q" }}, "You are helpful")
        local out = cjson.decode(anthropic.build_request(ctx))
        assert.equal("You are helpful", out.system)
        -- system-role message must NOT appear in messages array
        for _, m in ipairs(out.messages or {}) do
            assert.not_equal("system", m.role, "system role must not be in messages array")
        end
    end)

    it("passes max_tokens through to output body", function()
        reset()
        local ctx = make_compat_ctx()
        ctx.request_body.max_tokens = 2048
        local out = cjson.decode(anthropic.build_request(ctx))
        assert.equal(2048, out.max_tokens)
    end)

    it("passes temperature through when set", function()
        reset()
        local ctx = make_compat_ctx()
        ctx.request_body.temperature = 0.7
        local out = cjson.decode(anthropic.build_request(ctx))
        assert.not_nil(out.temperature)
    end)

    it("includes model in output", function()
        reset()
        local ctx = make_compat_ctx(nil, nil, "claude-3-haiku-20240307")
        local out = cjson.decode(anthropic.build_request(ctx))
        assert.equal("claude-3-haiku-20240307", out.model)
    end)

end)

-- ============================================================================
-- parse_response: token extraction including cache_deletion_tokens
-- ============================================================================

describe("anthropic.parse_response: token extraction", function()

    it("returns content from text blocks", function()
        reset()
        local body = cjson.encode({
            id      = "msg_001",
            type    = "message",
            role    = "assistant",
            content = {{ type="text", text="Hello world" }},
            usage   = { input_tokens=5, output_tokens=3 },
        })
        local result, err = anthropic.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello world", result.content)
    end)

    it("returns input_tokens and output_tokens", function()
        reset()
        local body = cjson.encode({
            content = {{ type="text", text="ok" }},
            usage   = { input_tokens=100, output_tokens=20 },
        })
        local r = anthropic.parse_response(body)
        assert.equal(100, r.input_tokens)
        assert.equal(20,  r.output_tokens)
    end)

    it("returns cache_deletion_input_tokens as cache_deletion_tokens", function()
        reset()
        local body = cjson.encode({
            content = {{ type="text", text="ok" }},
            usage   = {
                input_tokens                 = 50,
                output_tokens                = 10,
                cache_creation_input_tokens  = 200,
                cache_read_input_tokens      = 100,
                cache_deletion_input_tokens  = 75,
            },
        })
        local r = anthropic.parse_response(body)
        assert.equal(75,  r.cache_deletion_tokens)
        assert.equal(200, r.cache_creation_tokens)
        assert.equal(100, r.cache_read_tokens)
    end)

    it("returns nil, error for invalid JSON", function()
        reset()
        local r, err = anthropic.parse_response("not json")
        assert.is_nil(r)
        assert.not_nil(err)
    end)

    it("returns nil, error for provider error response", function()
        reset()
        local body = cjson.encode({
            type  = "error",
            error = { type="invalid_request_error", message="Bad request" },
        })
        local r, err = anthropic.parse_response(body)
        assert.is_nil(r)
        assert.equal("Bad request", err)
    end)

    it("skips non-text blocks (tool_use, thinking) in content extraction", function()
        reset()
        local body = cjson.encode({
            content = {
                { type="thinking", thinking="let me think" },
                { type="text",     text="result" },
                { type="tool_use", id="t1", name="fn", input={} },
            },
            usage = { input_tokens=1, output_tokens=1 },
        })
        local r = anthropic.parse_response(body)
        assert.equal("result", r.content)
    end)

end)

-- ============================================================================
-- parse_sse_chunk: state machine events
-- ============================================================================

describe("anthropic.parse_sse_chunk: state machine", function()

    local function sse(data)
        return "data: " .. cjson.encode(data)
    end

    it("message_start: extracts input_tokens and cache_deletion_tokens", function()
        reset()
        local line = sse({
            type    = "message_start",
            message = {
                usage = {
                    input_tokens                = 50,
                    cache_creation_input_tokens = 10,
                    cache_read_input_tokens     = 5,
                    cache_deletion_input_tokens = 3,
                },
            },
        })
        local r = anthropic.parse_sse_chunk(line, {})
        assert.equal(50, r.input_tokens)
        assert.equal(10, r.cache_creation_tokens)
        assert.equal(5,  r.cache_read_tokens)
        assert.equal(3,  r.cache_deletion_tokens)
    end)

    it("content_block_delta: returns text delta", function()
        reset()
        local line = sse({
            type  = "content_block_delta",
            index = 0,
            delta = { type="text_delta", text="Hello" },
        })
        local r = anthropic.parse_sse_chunk(line, {})
        assert.equal("Hello", r.delta)
        assert.is_false(r.done or false)
    end)

    it("message_stop: returns done=true", function()
        reset()
        local line = sse({ type = "message_stop" })
        local r = anthropic.parse_sse_chunk(line, {})
        assert.is_true(r.done)
    end)

    it("message_delta: captures stop_reason and output_tokens", function()
        reset()
        local line = sse({
            type  = "message_delta",
            delta = { stop_reason = "end_turn" },
            usage = { output_tokens = 42 },
        })
        local r = anthropic.parse_sse_chunk(line, {})
        assert.equal("end_turn", r.stop_reason)
        assert.equal(42, r.output_tokens)
    end)

    it("non-data line returns nil (parsed by upstream, not provider)", function()
        reset()
        -- Empty lines and SSE events without 'data: ' prefix are filtered by upstream
        local r = anthropic.parse_sse_chunk("", {})
        assert.is_nil(r, "non-data line must return nil — upstream handles SSE framing")
    end)

    it("[DONE] sentinel: json.decode fails → returns nil (upstream handles [DONE])", function()
        reset()
        -- [DONE] is not valid JSON, so parse_sse_chunk returns nil.
        -- upstream.lua checks for the [DONE] sentinel before calling parse_sse_chunk.
        local r = anthropic.parse_sse_chunk("data: [DONE]", {})
        assert.is_nil(r, "[DONE] must return nil — upstream intercepts it before parsing")
    end)

    it("content_block_start with thinking type emits '<think>' delta", function()
        reset()
        local st   = {}
        local line = sse({ type="content_block_start", index=0,
                           content_block={ type="thinking", thinking="" } })
        local r1 = anthropic.parse_sse_chunk(line, st)
        -- The thinking block start emits the '<think>' tag as the delta
        assert.not_nil(r1, "content_block_start must return a result")
        assert.equal("<think>", r1.delta,
            "thinking content_block_start must emit '<think>' tag")
        assert.is_true(st.thinking_opened, "thinking_opened flag must be set in state")
    end)

end)
