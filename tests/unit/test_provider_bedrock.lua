-- tests/unit/test_provider_bedrock.lua
-- Run with: busted tests/unit/test_provider_bedrock.lua

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

-- Minimal resty mocks (same pattern as test_sigv4.lua)
local FAKE_BYTES = string.rep("\xcd", 32)
local FAKE_HEX   = string.rep("cd", 32)

local function install_resty_mocks()
    package.preload["resty.sha256"] = function()
        return { new = function()
            return { update = function() end, final = function() return FAKE_BYTES end }
        end }
    end
    package.preload["resty.string"] = function()
        return { to_hex = function(s)
            return s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
        end }
    end
    package.preload["resty.hmac"] = function()
        return {
            ALGOS = { SHA256 = 1 },
            new   = function(self, key, _)
                return { update = function() end, final = function() return FAKE_BYTES end }
            end,
        }
    end
end

-- Clear first, then install mocks (clear() would wipe preload entries set before it).
clear({"providers.bedrock","utils.sigv4","utils.json","resty.sha256","resty.string","resty.hmac"})
install_resty_mocks()
local bedrock = require("providers.bedrock")
local cjson   = require("cjson.safe")

-- ── helpers ────────────────────────────────────────────────────────────────

local function ctx(model, messages, extras)
    local c = {
        model          = model,
        request_id     = "req-bedrock",
        gateway_config = {},
        request_body   = { messages = messages or {} },
    }
    for k, v in pairs(extras or {}) do c[k] = v end
    return c
end

local function decode_request(c)
    return cjson.decode(bedrock.build_request(c))
end

-- ── base_url ───────────────────────────────────────────────────────────────

describe("providers.bedrock — base_url", function()
    it("uses default us-east-1 region", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0")
        assert.equal(
            "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-3-5-sonnet-20241022-v2:0/invoke",
            bedrock.base_url(c))
    end)

    it("uses bedrock_region from gateway_config", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0")
        c.gateway_config.bedrock_region = "eu-west-1"
        assert(bedrock.base_url(c):find("eu%-west%-1"))
    end)
end)

-- ── build_request: Anthropic ───────────────────────────────────────────────

describe("providers.bedrock — build_request (anthropic.*)", function()
    it("produces Anthropic Messages format without model field", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {
            { role = "user", content = "Hello" }
        })
        local b = decode_request(c)
        assert.is_nil(b.model, "Bedrock Anthropic must NOT include model in body")
        assert.equal(1,       #b.messages)
        assert.equal("user",  b.messages[1].role)
        assert.equal("Hello", b.messages[1].content)
        assert.equal(4096,    b.max_tokens)
    end)

    it("extracts system message from messages array", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {
            { role = "system", content = "Be concise." },
            { role = "user",   content = "Hi" },
        })
        local b = decode_request(c)
        assert.equal("Be concise.", b.system)
        assert.equal(1, #b.messages)
        assert.equal("Hi", b.messages[1].content)
    end)

    it("forwards temperature and top_p", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        c.request_body.temperature = 0.5
        c.request_body.top_p       = 0.8
        local b = decode_request(c)
        assert.is_true(math.abs(b.temperature - 0.5) < 1e-9)
        assert.is_true(math.abs(b.top_p       - 0.8) < 1e-9)
    end)

    it("converts string stop to stop_sequences array", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        c.request_body.stop = "STOP"
        local b = decode_request(c)
        assert.equal(1,      #b.stop_sequences)
        assert.equal("STOP", b.stop_sequences[1])
    end)

    it("omits stream flag (Bedrock streaming not yet supported)", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        c.request_body.stream = true
        local b = decode_request(c)
        assert.is_nil(b.stream)
    end)
end)

-- ── build_request: Meta Llama ──────────────────────────────────────────────

describe("providers.bedrock — build_request (meta.*)", function()
    it("produces prompt string with Llama special tokens", function()
        local c = ctx("meta.llama3-3-70b-instruct-v1:0", {
            { role = "user", content = "Say hi" },
        })
        local b = decode_request(c)
        assert.not_nil(b.prompt)
        assert(b.prompt:find("<|begin_of_text|>"))
        assert(b.prompt:find("<|start_header_id|>user<|end_header_id|>"))
        assert(b.prompt:find("Say hi"))
        assert(b.prompt:find("<|eot_id|>"))
        assert(b.prompt:find("<|start_header_id|>assistant<|end_header_id|>"))
    end)

    it("includes system message with special tokens", function()
        local c = ctx("meta.llama3-3-70b-instruct-v1:0", {
            { role = "system", content = "Be brief." },
            { role = "user",   content = "What?" },
        })
        local b = decode_request(c)
        assert(b.prompt:find("system<|end_header_id|>"))
        assert(b.prompt:find("Be brief%."))
    end)

    it("maps max_tokens to max_gen_len", function()
        local c = ctx("meta.llama3-3-70b-instruct-v1:0", {})
        c.request_body.max_tokens = 128
        local b = decode_request(c)
        assert.equal(128, b.max_gen_len)
    end)
end)

-- ── build_request: Amazon Nova ────────────────────────────────────────────

describe("providers.bedrock — build_request (amazon.*)", function()
    it("produces Converse messages array with content blocks", function()
        local c = ctx("amazon.nova-pro-v1:0", {
            { role = "user", content = "Hello" },
        })
        local b = decode_request(c)
        assert.equal(1,       #b.messages)
        assert.equal("user",  b.messages[1].role)
        assert.equal("Hello", b.messages[1].content[1].text)
    end)

    it("extracts system into top-level system array", function()
        local c = ctx("amazon.nova-pro-v1:0", {
            { role = "system", content = "You are helpful." },
            { role = "user",   content = "Hi" },
        })
        local b = decode_request(c)
        assert.equal("You are helpful.", b.system[1].text)
        assert.equal(1, #b.messages)
    end)

    it("sets inferenceConfig when max_tokens or temperature provided", function()
        local c = ctx("amazon.nova-lite-v1:0", {})
        c.request_body.max_tokens  = 512
        c.request_body.temperature = 0.3
        local b = decode_request(c)
        assert.equal(512, b.inferenceConfig.maxTokens)
        assert.is_true(math.abs(b.inferenceConfig.temperature - 0.3) < 1e-9)
    end)

    it("omits inferenceConfig when no relevant params", function()
        local c = ctx("amazon.nova-micro-v1:0", {})
        local b = decode_request(c)
        assert.is_nil(b.inferenceConfig)
    end)
end)

-- ── build_request: Mistral ────────────────────────────────────────────────

describe("providers.bedrock — build_request (mistral.*)", function()
    it("produces prompt string with [INST] markers", function()
        local c = ctx("mistral.mistral-large-2402-v1:0", {
            { role = "user", content = "Explain AI" },
        })
        local b = decode_request(c)
        assert.not_nil(b.prompt)
        assert(b.prompt:find("%[INST%]"))
        assert(b.prompt:find("Explain AI"))
        assert(b.prompt:find("%[/INST%]"))
    end)
end)

-- ── build_headers ──────────────────────────────────────────────────────────

describe("providers.bedrock — build_headers", function()
    it("sets Content-Type and Authorization", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {
            { role = "user", content = "hi" }
        })
        local h = bedrock.build_headers(c, "AKID:SECRET")
        assert.equal("application/json", h["Content-Type"])
        assert.not_nil(h["Authorization"])
        assert(h["Authorization"]:find("^AWS4%-HMAC%-SHA256"))
    end)

    it("Authorization Credential contains access key", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        local h = bedrock.build_headers(c, "MYACCESSKEYID:mysecretkey")
        assert(h["Authorization"]:find("MYACCESSKEYID"))
    end)

    it("sets X-Amz-Security-Token when session token provided", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        local h = bedrock.build_headers(c, "AKI:SECRET:SessionToken123")
        assert.equal("SessionToken123", h["X-Amz-Security-Token"])
    end)

    it("omits X-Amz-Security-Token when no session token", function()
        local c = ctx("anthropic.claude-3-5-sonnet-20241022-v2:0", {})
        local h = bedrock.build_headers(c, "AKI:SECRET")
        assert.is_nil(h["X-Amz-Security-Token"])
    end)
end)

-- ── parse_response ─────────────────────────────────────────────────────────

describe("providers.bedrock — parse_response (Anthropic format)", function()
    it("extracts text content and token counts", function()
        local body = [[{
            "id": "msg-1",
            "type": "message",
            "content": [{"type": "text", "text": "Hi there"}],
            "usage": {"input_tokens": 10, "output_tokens": 4}
        }]]
        local r, err = bedrock.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hi there", r.content)
        assert.equal(10,         r.input_tokens)
        assert.equal(4,          r.output_tokens)
    end)
end)

describe("providers.bedrock — parse_response (Meta Llama format)", function()
    it("extracts generation and token counts", function()
        local body = [[{
            "generation": "Hello from Llama",
            "prompt_token_count": 7,
            "generation_token_count": 4,
            "stop_reason": "stop"
        }]]
        local r, err = bedrock.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello from Llama", r.content)
        assert.equal(7,  r.input_tokens)
        assert.equal(4,  r.output_tokens)
    end)
end)

describe("providers.bedrock — parse_response (Amazon Nova format)", function()
    it("extracts text from Converse output envelope", function()
        local body = [[{
            "output": {
                "message": {
                    "role": "assistant",
                    "content": [{"text": "Hello from Nova"}]
                }
            },
            "usage": {"inputTokens": 5, "outputTokens": 3}
        }]]
        local r, err = bedrock.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello from Nova", r.content)
        assert.equal(5,  r.input_tokens)
        assert.equal(3,  r.output_tokens)
    end)
end)

describe("providers.bedrock — parse_response (Mistral format)", function()
    it("extracts text from outputs array", function()
        local body = [[{"outputs":[{"text":"Mistral reply","stop_reason":"stop"}]}]]
        local r, err = bedrock.parse_response(body)
        assert.is_nil(err)
        assert.equal("Mistral reply", r.content)
    end)
end)

describe("providers.bedrock — parse_response (error cases)", function()
    it("returns error for Bedrock error envelope", function()
        local body = [[{"message": "The model ID is invalid"}]]
        local r, err = bedrock.parse_response(body)
        assert.is_nil(r)
        assert.equal("The model ID is invalid", err)
    end)

    it("returns error for json decode failure", function()
        local r, err = bedrock.parse_response("{bad")
        assert.is_nil(r)
        assert.equal("json decode failed", err)
    end)

    it("returns error for unrecognized format", function()
        local r, err = bedrock.parse_response([[{"unknown_field": "value"}]])
        assert.is_nil(r)
        assert.not_nil(err)
    end)
end)

describe("providers.bedrock — parse_sse_chunk", function()
    it("always returns nil (streaming not yet supported)", function()
        assert.is_nil(bedrock.parse_sse_chunk("data: anything"))
        assert.is_nil(bedrock.parse_sse_chunk(""))
    end)
end)
