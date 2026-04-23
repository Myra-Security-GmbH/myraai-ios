-- tests/unit/test_providers_thin.lua — contract tests for thin provider adapters
-- Run with: resty tests/runner.lua tests/unit/test_providers_thin.lua
--
-- Covers:
--   azure, cerebras, cloudflare, groq, huggingface, mistral, nvidia,
--   sambanova (all ≤38 lines, inherit from openai);
--   providers/init.lua: registry get(), known(), registry_entry(), list()
--   providers/vllm.lua: base_url override, build_request strips "vllm/" prefix

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

_G.ngx = {
    encode_base64  = _real_encode_base64,
    decode_base64  = _real_decode_base64,
    log            = function() end,
    exit           = function(c) error(c, 0) end,
    print          = function() end,
    status         = 200,
    header         = {},
    req            = { get_headers = function() return {} end },
    var            = {},
    ctx            = {},
    ERR            = 0, WARN = 1, INFO = 2,
    now            = function() return 1700000000.0 end,
    time           = function() return 1700000000 end,
}

for _, n in ipairs({"core.app_config","state","utils.json","utils.trace","utils.uuid"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return {
        defaults = { prompt_caching={enabled=false}, context_compaction={enabled=false} },
        provider_base_urls = nil,
    }
end

package.preload["state"] = function()
    local c = {}
    return { config_get=function(k) return c[k] end, config_set=function(k,v) c[k]=v end }
end

package.preload["utils.json"] = function()
    local j = {}
    j.encode = cjson.encode
    j.decode = cjson.decode
    j.null   = cjson.null
    j.sanitize_surrogates = function(s) return s end
    return j
end

package.preload["utils.trace"] = function()
    return { step=function() end, done=function() end }
end

package.preload["utils.uuid"] = function()
    local n = 0
    return { v4 = function() n=n+1; return "uuid-"..n end }
end

-- ============================================================================
-- Helper: standard ctx for build_request
-- ============================================================================

local function make_ctx(model, provider_path)
    return {
        is_compat      = true,
        request_id     = "req-001",
        model          = model or "gpt-4o",
        provider       = "openai",
        provider_path  = provider_path or "/v1/chat/completions",
        gateway_config = {
            prompt_caching     = { enabled=false },
            context_compaction = { enabled=false },
        },
        request_body   = {
            model    = model or "gpt-4o",
            messages = {{ role="user", content="test" }},
            max_tokens = 100,
        },
        raw_request_body = cjson.encode({
            model    = model or "gpt-4o",
            messages = {{ role="user", content="test" }},
            max_tokens = 100,
        }),
    }
end

-- ============================================================================
-- Thin providers: contract tests
-- ============================================================================

-- All providers must implement these 5 exports
local REQUIRED_EXPORTS = { "base_url", "build_headers", "build_request",
                           "parse_response", "parse_sse_chunk" }

local THIN_PROVIDERS = {
    -- { name, module, expected_url_fragment, auth_header }
    { "azure",       "providers.azure",       "openai.azure.com",  "api-key" },
    { "cerebras",    "providers.cerebras",    "cerebras.ai",       "Authorization" },
    { "cloudflare",  "providers.cloudflare",  "cloudflare.com",    "Authorization" },
    { "groq",        "providers.groq",        "groq.com",          "Authorization" },
    { "huggingface", "providers.huggingface", "huggingface.co",    "Authorization" },
    { "mistral",     "providers.mistral",     "mistral.ai",        "Authorization" },
    { "nvidia",      "providers.nvidia",      "nvidia.com",        "Authorization" },
    { "sambanova",   "providers.sambanova",   "sambanova.ai",      "Authorization" },
}

for _, spec in ipairs(THIN_PROVIDERS) do
    local name, module_name, url_fragment, auth_hdr = spec[1], spec[2], spec[3], spec[4]

    describe("providers." .. name .. ": contract", function()

        local mod
        before_each(function()
            package.loaded[module_name] = nil
            mod = require(module_name)
        end)

        it("exports all required functions", function()
            for _, fn in ipairs(REQUIRED_EXPORTS) do
                assert.equal("function", type(mod[fn]),
                    name .. "." .. fn .. " must be a function")
            end
        end)

        it("base_url() returns a non-empty HTTPS string", function()
            local ctx = make_ctx()
            ctx.gateway_config.azure_resource   = "my-res"
            ctx.gateway_config.azure_api_version = "2024-10-21"
            ctx.gateway_config.azure_deployment  = "gpt-4o"
            local url = mod.base_url(ctx)
            assert.equal("string", type(url))
            assert.is_true(#url > 0, name .. ".base_url must be non-empty")
            assert.is_true(url:find(url_fragment) ~= nil or url:find("http") ~= nil,
                name .. ".base_url should reference provider domain or be HTTP(S)")
        end)

        it("build_headers() includes the expected auth header", function()
            local ctx = make_ctx()
            local headers = mod.build_headers(ctx, "test-api-key")
            assert.not_nil(headers[auth_hdr],
                name .. ".build_headers must include " .. auth_hdr)
        end)

        it("delegates parse_response to openai", function()
            -- Feed a valid OpenAI-style response body
            local body = cjson.encode({
                choices = {{ message={ role="assistant", content="ok" }, finish_reason="stop" }},
                usage   = { prompt_tokens=5, completion_tokens=3, total_tokens=8 },
            })
            local r = mod.parse_response(body)
            assert.not_nil(r, name .. ".parse_response must return a result")
        end)

        it("delegates parse_sse_chunk [DONE] to openai → done=true", function()
            local r = mod.parse_sse_chunk("data: [DONE]", {})
            assert.is_true(r.done, name .. ".parse_sse_chunk [DONE] must return done=true")
        end)

    end)
end

-- ============================================================================
-- providers/init.lua
-- ============================================================================

describe("providers/init.lua: registry", function()

    local providers = require("providers")

    it("get('openai') returns a module with required exports", function()
        local mod, err = providers.get("openai")
        assert.is_nil(err)
        assert.not_nil(mod)
        for _, fn in ipairs(REQUIRED_EXPORTS) do
            assert.equal("function", type(mod[fn]), "openai." .. fn .. " must exist")
        end
    end)

    it("get('anthropic') returns a module", function()
        local mod, err = providers.get("anthropic")
        assert.is_nil(err)
        assert.not_nil(mod)
    end)

    it("get('unknown') returns nil + error string", function()
        local mod, err = providers.get("unknown_provider_xyz")
        assert.is_nil(mod)
        assert.not_nil(err)
        assert(tostring(err):find("unknown"), "error must mention 'unknown'")
    end)

    it("known() returns true for registered providers", function()
        assert.is_true(providers.known("openai"))
        assert.is_true(providers.known("anthropic"))
        assert.is_true(providers.known("ollama"))
    end)

    it("known() returns false for unknown providers", function()
        assert.is_false(providers.known("fake_provider"))
    end)

    it("registry_entry() returns requires_key for known providers", function()
        local entry = providers.registry_entry("openai")
        assert.not_nil(entry)
        assert.equal(true, entry.requires_key)
        local ollama = providers.registry_entry("ollama")
        assert.equal(false, ollama.requires_key)
    end)

    it("list() returns all registered providers sorted by name", function()
        local list = providers.list()
        assert.is_true(#list > 5, "list must have many providers")
        -- Check sorted
        for i = 2, #list do
            assert.is_true(list[i-1].name <= list[i].name,
                "list must be sorted alphabetically")
        end
    end)

end)

-- ============================================================================
-- providers/vllm.lua
-- ============================================================================

describe("providers.vllm: base_url and build_request", function()

    local vllm

    before_each(function()
        package.loaded["providers.vllm"] = nil
        vllm = require("providers.vllm")
    end)

    it("base_url uses DEFAULT_BASE when no overrides", function()
        local ctx = {
            provider_path  = "/v1/chat/completions",
            gateway_config = {},
            request_body   = { model="qwen3-235b" },
        }
        local url = vllm.base_url(ctx)
        assert.is_true(url:find("127%.0%.0%.1") ~= nil or url:find("http") ~= nil,
            "default vllm URL must be an HTTP address")
        assert.is_true(url:find("/v1/chat/completions") ~= nil)
    end)

    it("base_url uses gateway config provider_base_urls.vllm override", function()
        local ctx = {
            provider_path  = "/v1/chat/completions",
            gateway_config = {
                provider_base_urls = { vllm = "http://my-vllm-server:9000" },
            },
            request_body   = { model="qwen3-235b" },
        }
        local url = vllm.base_url(ctx)
        assert.is_true(url:find("my%-vllm%-server:9000") ~= nil,
            "should use gateway config override: " .. url)
    end)

    it("build_request strips 'vllm/' prefix from model name", function()
        local ctx = make_ctx("vllm/Qwen3-235B-A22B-AWQ")
        ctx.gateway_config.provider_base_urls = nil
        local out_str = vllm.build_request(ctx)
        local out = cjson.decode(out_str)
        assert.not_nil(out)
        assert.equal("Qwen3-235B-A22B-AWQ", out.model,
            "vllm/ prefix must be stripped from model name in request")
    end)

    it("build_request passes through model without 'vllm/' prefix unchanged", function()
        local ctx = make_ctx("qwen3-235b")
        ctx.gateway_config.provider_base_urls = nil
        local out_str = vllm.build_request(ctx)
        local out = cjson.decode(out_str)
        assert.equal("qwen3-235b", out.model)
    end)

    it("requires_key=false in provider registry", function()
        local providers = require("providers")
        local entry = providers.registry_entry("vllm")
        assert.not_nil(entry)
        assert.equal(false, entry.requires_key)
    end)

    it("exports all required functions", function()
        for _, fn in ipairs(REQUIRED_EXPORTS) do
            assert.equal("function", type(vllm[fn]), "vllm." .. fn .. " must be a function")
        end
    end)

end)
