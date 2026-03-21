-- tests/unit/test_compat.lua
-- Tests for providers/compat.lua: infer_provider() and provider_path()
--
-- Run with: busted tests/unit/test_compat.lua

_G.ngx = {
    now  = function() return 1700000000.0 end,
    log  = function() end,
    var  = { http_x_request_id = "" },
    req  = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Force fresh load
package.loaded["providers.compat"] = nil
local compat = require("providers.compat")

-- ── exact map ────────────────────────────────────────────────────────────────

describe("providers.compat.infer_provider — exact map", function()
    it("gpt-4o → openai", function()
        assert.equal("openai", compat.infer_provider("gpt-4o"))
    end)
    it("gpt-4o-mini → openai", function()
        assert.equal("openai", compat.infer_provider("gpt-4o-mini"))
    end)
    it("o1 → openai", function()
        assert.equal("openai", compat.infer_provider("o1"))
    end)
    it("claude-sonnet-4-6 → anthropic", function()
        assert.equal("anthropic", compat.infer_provider("claude-sonnet-4-6"))
    end)
    it("claude-3-5-sonnet-20241022 → anthropic", function()
        assert.equal("anthropic", compat.infer_provider("claude-3-5-sonnet-20241022"))
    end)
    it("gemini-2.0-flash → gemini", function()
        assert.equal("gemini", compat.infer_provider("gemini-2.0-flash"))
    end)
    it("gemini-1.5-pro → gemini", function()
        assert.equal("gemini", compat.infer_provider("gemini-1.5-pro"))
    end)
    it("mistral-large-latest → mistral", function()
        assert.equal("mistral", compat.infer_provider("mistral-large-latest"))
    end)
    it("command-r-plus → cohere", function()
        assert.equal("cohere", compat.infer_provider("command-r-plus"))
    end)
    it("deepseek-chat → deepseek", function()
        assert.equal("deepseek", compat.infer_provider("deepseek-chat"))
    end)
    it("grok-3 → xai", function()
        assert.equal("xai", compat.infer_provider("grok-3"))
    end)
    it("sonar-pro → perplexity", function()
        assert.equal("perplexity", compat.infer_provider("sonar-pro"))
    end)
    it("meta-llama/Llama-3.3-70B-Instruct-Turbo → together", function()
        assert.equal("together",
            compat.infer_provider("meta-llama/Llama-3.3-70B-Instruct-Turbo"))
    end)
    it("accounts/fireworks/models/deepseek-v3 → fireworks", function()
        assert.equal("fireworks",
            compat.infer_provider("accounts/fireworks/models/deepseek-v3"))
    end)
    it("llama3.3-70b → cerebras", function()
        assert.equal("cerebras", compat.infer_provider("llama3.3-70b"))
    end)
    it("Meta-Llama-3.3-70B-Instruct → sambanova", function()
        assert.equal("sambanova",
            compat.infer_provider("Meta-Llama-3.3-70B-Instruct"))
    end)
end)

-- ── prefix map ───────────────────────────────────────────────────────────────

describe("providers.compat.infer_provider — prefix map", function()
    it("gpt-4-turbo-preview → openai  (gpt prefix)", function()
        assert.equal("openai", compat.infer_provider("gpt-4-turbo-preview"))
    end)
    it("o3-future → openai  (o3 prefix)", function()
        assert.equal("openai", compat.infer_provider("o3-future"))
    end)
    it("claude-3-haiku-99 → anthropic  (claude prefix)", function()
        assert.equal("anthropic", compat.infer_provider("claude-3-haiku-99"))
    end)
    it("gemini-experimental → gemini  (gemini prefix)", function()
        assert.equal("gemini", compat.infer_provider("gemini-experimental"))
    end)
    it("deepseek-v4 → deepseek  (deepseek prefix)", function()
        assert.equal("deepseek", compat.infer_provider("deepseek-v4"))
    end)
    it("grok-99-ultra → xai  (grok prefix)", function()
        assert.equal("xai", compat.infer_provider("grok-99-ultra"))
    end)
    it("sonar-turbo → perplexity  (sonar prefix)", function()
        assert.equal("perplexity", compat.infer_provider("sonar-turbo"))
    end)
    it("@cf/meta/llama-3 → cloudflare  (@cf/ prefix)", function()
        assert.equal("cloudflare", compat.infer_provider("@cf/meta/llama-3"))
    end)
    it("meta.llama3-future → bedrock  (meta. prefix with dot)", function()
        assert.equal("bedrock", compat.infer_provider("meta.llama3-future"))
    end)
    it("anthropic.claude-future → bedrock  (anthropic. prefix)", function()
        assert.equal("bedrock", compat.infer_provider("anthropic.claude-future"))
    end)
    it("amazon.nova-v9 → bedrock  (amazon. prefix)", function()
        assert.equal("bedrock", compat.infer_provider("amazon.nova-v9"))
    end)
    it("Qwen/Qwen3-72B → together  (Qwen/ prefix)", function()
        assert.equal("together", compat.infer_provider("Qwen/Qwen3-72B"))
    end)
    it("nvidia/future-model → nvidia  (nvidia/ prefix)", function()
        assert.equal("nvidia", compat.infer_provider("nvidia/future-model"))
    end)
end)

-- ── HuggingFace prefixes (step 5) ────────────────────────────────────────────

describe("providers.compat.infer_provider — HuggingFace prefixes", function()
    it("HuggingFaceH4/zephyr-7b-beta → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("HuggingFaceH4/zephyr-7b-beta"))
    end)
    it("tiiuae/falcon-40b → huggingface", function()
        assert.equal("huggingface", compat.infer_provider("tiiuae/falcon-40b"))
    end)
    it("bigcode/starcoder2-15b → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("bigcode/starcoder2-15b"))
    end)
    it("EleutherAI/gpt-neox-20b → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("EleutherAI/gpt-neox-20b"))
    end)
    it("microsoft/phi-3-mini → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("microsoft/phi-3-mini"))
    end)
    it("google/gemma-7b → huggingface  (HF-hosted, not Gemini API)", function()
        assert.equal("huggingface",
            compat.infer_provider("google/gemma-7b"))
    end)
    it("stabilityai/stable-diffusion-xl → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("stabilityai/stable-diffusion-xl"))
    end)
    it("mistralai/Mistral-7B-Instruct-v0.3 → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("mistralai/Mistral-7B-Instruct-v0.3"))
    end)
    it("sentence-transformers/all-MiniLM-L6-v2 → huggingface", function()
        assert.equal("huggingface",
            compat.infer_provider("sentence-transformers/all-MiniLM-L6-v2"))
    end)
end)

-- ── OpenRouter fallback (step 1) ─────────────────────────────────────────────

describe("providers.compat.infer_provider — OpenRouter fallback", function()
    it("totally-unknown-model → openrouter", function()
        assert.equal("openrouter",
            compat.infer_provider("totally-unknown-model"))
    end)
    it("some/new/unknown/model → openrouter", function()
        assert.equal("openrouter",
            compat.infer_provider("some/new/unknown/model"))
    end)
    it("vendor-x/model-v999 → openrouter", function()
        assert.equal("openrouter",
            compat.infer_provider("vendor-x/model-v999"))
    end)
    it("nil model → openrouter", function()
        assert.equal("openrouter", compat.infer_provider(nil))
    end)
    it("empty string → openrouter", function()
        assert.equal("openrouter", compat.infer_provider(""))
    end)
end)

-- ── provider_path ─────────────────────────────────────────────────────────────

describe("providers.compat.provider_path", function()
    it("/compat/chat/completions → /v1/chat/completions", function()
        assert.equal("/v1/chat/completions",
            compat.provider_path("/compat/chat/completions"))
    end)
    it("/compat/embeddings → /v1/embeddings", function()
        assert.equal("/v1/embeddings",
            compat.provider_path("/compat/embeddings"))
    end)
    it("/compat/completions → /v1/completions", function()
        assert.equal("/v1/completions",
            compat.provider_path("/compat/completions"))
    end)
end)
