-- tests/unit/test_provider_ollama.lua
-- Run with: busted tests/unit/test_provider_ollama.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = { http_x_request_id = "" },
    req    = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

for _, n in ipairs({"providers.ollama","providers.openai","utils.json","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end
-- mock app_config so tests are isolated from the system config
package.preload["core.app_config"] = function() return {} end

local ollama = require("providers.ollama")
local json   = require("utils.json")

local function make_ctx(model, extra)
    local body = { model = model, messages = {{ role = "user", content = "hi" }} }
    for k, v in pairs(extra or {}) do body[k] = v end
    return {
        request_id     = "test-req",
        provider_path  = "/v1/chat/completions",
        gateway_config = {},
        request_body   = body,
    }
end

-- ── base_url ──────────────────────────────────────────────────────────────────

describe("providers.ollama.base_url", function()
    it("uses DEFAULT_BASE when no gateway override", function()
        local ctx = { gateway_config = {}, provider_path = "/v1/chat/completions" }
        assert.not_equal(nil, ollama.base_url(ctx):find("/v1/chat/completions"))
    end)

    it("uses gateway provider_base_urls.ollama when set", function()
        local ctx = {
            gateway_config = { provider_base_urls = { ollama = "http://myhost:9999" } },
            provider_path  = "/v1/chat/completions",
        }
        assert.equal("http://myhost:9999/v1/chat/completions", ollama.base_url(ctx))
    end)
end)

-- ── build_request: model prefix stripping ────────────────────────────────────

describe("providers.ollama.build_request — model prefix", function()
    it("strips 'ollama/' prefix before sending to Ollama API", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b")))
        assert.equal("qwen2.5:3b", body.model)
    end)

    it("strips 'ollama/' prefix for nested model names", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/llama3.1:70b")))
        assert.equal("llama3.1:70b", body.model)
    end)

    it("leaves bare model names unchanged", function()
        local body = json.decode(ollama.build_request(make_ctx("mistral")))
        assert.equal("mistral", body.model)
    end)
end)

-- ── build_request: temperature passthrough ───────────────────────────────────

describe("providers.ollama.build_request — temperature passthrough", function()
    it("passes temperature=0 to Ollama", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { temperature = 0 })))
        assert.equal(0, body.temperature)
    end)

    it("passes temperature=0.3 to Ollama", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { temperature = 0.3 })))
        assert.equal(0.3, body.temperature)
    end)

    it("passes temperature=1.0 to Ollama", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { temperature = 1.0 })))
        assert.equal(1.0, body.temperature)
    end)

    it("passes temperature=2.0 to Ollama", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { temperature = 2.0 })))
        assert.equal(2.0, body.temperature)
    end)

    it("omits temperature when not provided", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b")))
        assert.is_nil(body.temperature)
    end)
end)

-- ── build_request: other params passthrough ──────────────────────────────────

describe("providers.ollama.build_request — other params", function()
    it("passes max_tokens to Ollama", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { max_tokens = 512 })))
        assert.equal(512, body.max_tokens)
    end)

    it("passes messages unchanged", function()
        local ctx = make_ctx("ollama/qwen2.5:3b")
        ctx.request_body.messages = {{ role = "system", content = "be helpful" }, { role = "user", content = "hello" }}
        local body = json.decode(ollama.build_request(ctx))
        assert.equal(2, #body.messages)
        assert.equal("system", body.messages[1].role)
    end)

    it("preserves stream flag", function()
        local body = json.decode(ollama.build_request(make_ctx("ollama/qwen2.5:3b", { stream = true })))
        assert.is_true(body.stream)
    end)
end)

-- ── build_request: think parameter injection ─────────────────────────────────

describe("providers.ollama.build_request — think injection", function()

    local function make_ollama_with_config(app_cfg)
        for _, n in ipairs({"providers.ollama","core.app_config"}) do
            package.loaded[n] = nil; package.preload[n] = nil
        end
        package.preload["core.app_config"] = function() return app_cfg end
        return require("providers.ollama")
    end

    it("injects think=false when system config sets ollama.think=false", function()
        local ol = make_ollama_with_config({ ollama = { think = false } })
        local body = json.decode(ol.build_request(make_ctx("ollama/gpt-oss:20b")))
        assert.is_false(body.think)
    end)

    it("injects think=true when system config sets ollama.think=true", function()
        local ol = make_ollama_with_config({ ollama = { think = true } })
        local body = json.decode(ol.build_request(make_ctx("ollama/gpt-oss:20b")))
        assert.is_true(body.think)
    end)

    it("does not inject think when system config has no ollama.think", function()
        local ol = make_ollama_with_config({})
        local body = json.decode(ol.build_request(make_ctx("ollama/gpt-oss:20b")))
        assert.is_nil(body.think)
    end)

    it("per-gateway think=true overrides system config think=false", function()
        local ol = make_ollama_with_config({ ollama = { think = false } })
        local ctx = make_ctx("ollama/gpt-oss:20b")
        ctx.gateway_config = { ollama = { think = true } }
        local body = json.decode(ol.build_request(ctx))
        assert.is_true(body.think)
    end)

    it("per-gateway think=false overrides system config think=true", function()
        local ol = make_ollama_with_config({ ollama = { think = true } })
        local ctx = make_ctx("ollama/gpt-oss:20b")
        ctx.gateway_config = { ollama = { think = false } }
        local body = json.decode(ol.build_request(ctx))
        assert.is_false(body.think)
    end)

    it("think injection works for bare model names too (no ollama/ prefix)", function()
        local ol = make_ollama_with_config({ ollama = { think = false } })
        local body = json.decode(ol.build_request(make_ctx("gpt-oss:20b")))
        assert.is_false(body.think)
        assert.equal("gpt-oss:20b", body.model)  -- unchanged
    end)

    it("does not mutate the original ctx.request_body", function()
        local ol = make_ollama_with_config({ ollama = { think = false } })
        local ctx = make_ctx("ollama/gpt-oss:20b")
        ol.build_request(ctx)
        assert.is_nil(ctx.request_body.think,   "original body must not be mutated")
        assert.equal("ollama/gpt-oss:20b", ctx.request_body.model)
    end)

end)
