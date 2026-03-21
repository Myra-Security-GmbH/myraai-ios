-- tests/unit/test_providers_tier1.lua
-- Tests for the seven OpenAI-compatible Tier 1 providers:
--   together, fireworks, deepseek, xai, perplexity, openrouter, ollama
--
-- Run with: busted tests/unit/test_providers_tier1.lua

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

-- ── helpers ────────────────────────────────────────────────────────────────

-- Build a minimal ctx for base_url / build_headers tests.
local function ctx(overrides)
    local c = {
        provider_path  = "/v1/chat/completions",
        request_id     = "req-test",
        gateway_config = {},
        request_body   = { messages = {}, model = "some-model" },
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

-- ── Together AI ────────────────────────────────────────────────────────────

describe("providers.together", function()
    clear({"providers.together","providers.openai","utils.json"})
    local together = require("providers.together")

    it("base_url uses Together base + provider_path", function()
        assert.equal(
            "https://api.together.xyz/v1/chat/completions",
            together.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = together.build_headers(ctx(), "tok-together")
        assert.equal("Bearer tok-together", h["Authorization"])
        assert.equal("application/json",    h["Content-Type"])
    end)

    it("delegates parse_response to openai", function()
        local body = [[{
            "choices":[{"message":{"content":"Hi"},"finish_reason":"stop"}],
            "usage":{"prompt_tokens":5,"completion_tokens":3}
        }]]
        local r, err = together.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hi", r.content)
        assert.equal(5,    r.input_tokens)
        assert.equal(3,    r.output_tokens)
    end)

    it("delegates parse_sse_chunk to openai", function()
        local r = together.parse_sse_chunk(
            [[data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}]])
        assert.not_nil(r)
        assert.equal("ok", r.delta)
        assert.is_false(r.done)
    end)
end)

-- ── Fireworks AI ───────────────────────────────────────────────────────────

describe("providers.fireworks", function()
    clear({"providers.fireworks","providers.openai","utils.json"})
    local fireworks = require("providers.fireworks")

    it("base_url uses Fireworks base + provider_path", function()
        assert.equal(
            "https://api.fireworks.ai/inference/v1/chat/completions",
            fireworks.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = fireworks.build_headers(ctx(), "tok-fw")
        assert.equal("Bearer tok-fw",    h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)

    it("parse_sse_chunk [DONE] returns done=true", function()
        local r = fireworks.parse_sse_chunk("data: [DONE]")
        assert.is_true(r.done)
    end)
end)

-- ── DeepSeek ───────────────────────────────────────────────────────────────

describe("providers.deepseek", function()
    clear({"providers.deepseek","providers.openai","utils.json"})
    local deepseek = require("providers.deepseek")

    it("base_url uses DeepSeek base + provider_path", function()
        assert.equal(
            "https://api.deepseek.com/v1/chat/completions",
            deepseek.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = deepseek.build_headers(ctx(), "tok-ds")
        assert.equal("Bearer tok-ds",    h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)

    it("parse_response returns provider error message", function()
        local _, err = deepseek.parse_response(
            [[{"error":{"message":"quota exceeded","type":"quota"}}]])
        assert.equal("quota exceeded", err)
    end)
end)

-- ── xAI ────────────────────────────────────────────────────────────────────

describe("providers.xai", function()
    clear({"providers.xai","providers.openai","utils.json"})
    local xai = require("providers.xai")

    it("base_url uses xAI base + provider_path", function()
        assert.equal(
            "https://api.x.ai/v1/chat/completions",
            xai.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = xai.build_headers(ctx(), "tok-xai")
        assert.equal("Bearer tok-xai",   h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)
end)

-- ── Perplexity ─────────────────────────────────────────────────────────────

describe("providers.perplexity", function()
    clear({"providers.perplexity","providers.openai","utils.json"})
    local perplexity = require("providers.perplexity")

    it("base_url uses Perplexity base + provider_path", function()
        assert.equal(
            "https://api.perplexity.ai/v1/chat/completions",
            perplexity.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = perplexity.build_headers(ctx(), "tok-ppl")
        assert.equal("Bearer tok-ppl",   h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)
end)

-- ── OpenRouter ─────────────────────────────────────────────────────────────

describe("providers.openrouter", function()
    clear({"providers.openrouter","providers.openai","utils.json"})
    local openrouter = require("providers.openrouter")

    it("base_url uses OpenRouter base + provider_path", function()
        assert.equal(
            "https://openrouter.ai/api/v1/chat/completions",
            openrouter.base_url(ctx()))
    end)

    it("build_headers sets Bearer Authorization", function()
        local h = openrouter.build_headers(ctx(), "tok-or")
        assert.equal("Bearer tok-or",    h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)

    it("build_headers sets required HTTP-Referer and X-Title", function()
        local h = openrouter.build_headers(ctx(), "tok-or")
        assert.not_nil(h["HTTP-Referer"], "HTTP-Referer must be set")
        assert.not_nil(h["X-Title"],      "X-Title must be set")
    end)
end)

-- ── Ollama ─────────────────────────────────────────────────────────────────

describe("providers.ollama", function()
    clear({"providers.ollama","providers.openai","utils.json"})
    local ollama = require("providers.ollama")

    it("base_url defaults to localhost:11434", function()
        assert.equal(
            "http://localhost:11434/v1/chat/completions",
            ollama.base_url(ctx()))
    end)

    it("base_url uses custom URL from gateway_config.provider_base_urls.ollama", function()
        local c = ctx({
            gateway_config = {
                provider_base_urls = { ollama = "http://ollama.internal:11434" }
            }
        })
        assert.equal(
            "http://ollama.internal:11434/v1/chat/completions",
            ollama.base_url(c))
    end)

    it("build_headers omits Authorization when api_key is empty", function()
        local h = ollama.build_headers(ctx(), "")
        assert.is_nil(h["Authorization"])
    end)

    it("build_headers omits Authorization when api_key is nil", function()
        local h = ollama.build_headers(ctx(), nil)
        assert.is_nil(h["Authorization"])
    end)

    it("build_headers sets Authorization when api_key is provided", function()
        local h = ollama.build_headers(ctx(), "ollama-token")
        assert.equal("Bearer ollama-token", h["Authorization"])
    end)

    it("always sets Content-Type", function()
        local h = ollama.build_headers(ctx(), "")
        assert.equal("application/json", h["Content-Type"])
    end)
end)

-- ── provider registry ──────────────────────────────────────────────────────

describe("providers.init — new providers registered", function()
    clear({
        "providers.init","providers.openai","providers.anthropic","providers.gemini",
        "providers.mistral","providers.groq","providers.cohere","providers.bedrock",
        "providers.vertex","providers.together","providers.fireworks","providers.deepseek",
        "providers.xai","providers.perplexity","providers.openrouter","providers.ollama",
        "utils.json","utils.sigv4","utils.crypto",
    })

    -- Stub out resty modules that Bedrock/sigv4 pull in
    package.preload["resty.sha256"] = function()
        return { new = function() return {
            update = function() end,
            final  = function() return string.rep("\x00", 32) end
        } end }
    end
    package.preload["resty.string"] = function()
        return { to_hex = function(s)
            return s:gsub(".", function(c)
                return string.format("%02x", string.byte(c))
            end)
        end }
    end
    package.preload["resty.hmac"] = function()
        return {
            ALGOS = { SHA256 = 1 },
            new   = function(self, key, _)
                return {
                    update = function() end,
                    final  = function() return string.rep("\x00", 32) end,
                }
            end,
        }
    end

    local init = require("providers.init")

    local expected = {
        "openai","anthropic","gemini","cohere","bedrock","vertex",
        "mistral","groq","together","fireworks","deepseek",
        "xai","perplexity","openrouter","ollama",
    }
    for _, name in ipairs(expected) do
        it("provider '" .. name .. "' is registered and loadable", function()
            local mod, err = init.get(name)
            assert.is_nil(err,    name .. " load error: " .. tostring(err))
            assert.not_nil(mod,   name .. " module should not be nil")
            assert(type(mod.base_url) == "function",       name .. ".base_url must be a function")
            assert(type(mod.build_headers) == "function",  name .. ".build_headers must be a function")
            assert(type(mod.build_request) == "function",  name .. ".build_request must be a function")
            assert(type(mod.parse_response) == "function", name .. ".parse_response must be a function")
            assert(type(mod.parse_sse_chunk) == "function", name .. ".parse_sse_chunk must be a function")
        end)
    end

    it("unknown provider returns nil + error", function()
        local mod, err = init.get("no-such-provider")
        assert.is_nil(mod)
        assert.not_nil(err)
    end)
end)
