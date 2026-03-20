-- tests/fixtures/seed_mock.lua — seed a "mock" gateway that routes to the mock provider
-- Run with: AIG_CONFIG=config/gateway.lua resty -I src/ tests/fixtures/seed_mock.lua
--
-- Creates:
--   tenant:  "test-tenant"   (reuses if exists)
--   gateway: "mock"          (auth disabled, cache 60s, all providers → 127.0.0.1:19000)
--   BYOK:    openai/anthropic/gemini → "mock-key" (accepted by mock provider)
--   token:   "mock-token-1234"

package.path = package.path .. ";src/?.lua;src/?/init.lua"

_G.ngx = {
    shared   = {},
    log      = function(_, ...) io.write(table.concat({...}, " ") .. "\n") end,
    now      = function() return os.time() end,
    encode_base64 = function(s) return s end,
    ERR = 0, WARN = 1, INFO = 2, NOTICE = 3, DEBUG = 4,
}

local cfg    = dofile("config/gateway.lua")
local sqlite = require("storage.sqlite")
local byok   = require("auth.byok")
local crypto = require("utils.crypto")

sqlite.init(cfg)

local tenant_id = sqlite.upsert_tenant("test-tenant", "free", 100.0)
print("tenant_id  = " .. tenant_id)

local gw_config = {
    auth_required = false,
    cache_ttl     = 60,
    retry_count   = 1,
    log_payloads  = true,
    rate_limit    = { requests = 1000, window_sec = 60 },
    -- Route all provider calls to the mock server
    provider_base_urls = {
        openai    = "http://127.0.0.1:19000",
        anthropic = "http://127.0.0.1:19000",
        gemini    = "http://127.0.0.1:19000",
        mistral   = "http://127.0.0.1:19000",
        groq      = "http://127.0.0.1:19000",
    },
}

local gateway_id = sqlite.upsert_gateway(tenant_id, "mock", gw_config)
print("gateway_id = " .. gateway_id)

for _, provider in ipairs({"openai", "anthropic", "gemini", "mistral", "groq"}) do
    byok.store_key(gateway_id, provider, "default", "mock-key-" .. provider)
    print("stored key: " .. provider)
end

local raw_token = "mock-token-1234"
local hash      = crypto.sha256_hex(raw_token)
sqlite.insert_auth_token(gateway_id, hash, {"read", "write"}, nil)
print("auth token: " .. raw_token)

print("\nExample requests:")
print("  curl -s http://127.0.0.1:8081/v1/test-tenant/mock/openai/v1/chat/completions \\")
print("    -H 'Content-Type: application/json' \\")
print("    -d '{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}'")
print("")
print("  # Streaming:")
print("  curl -s http://127.0.0.1:8081/v1/test-tenant/mock/openai/v1/chat/completions \\")
print("    -H 'Content-Type: application/json' \\")
print("    -d '{\"model\":\"gpt-4o-mini\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}'")
print("")
print("  # Force 500:")
print("  curl -s http://127.0.0.1:8081/v1/test-tenant/mock/openai/v1/chat/completions \\")
print("    -H 'Content-Type: application/json' \\")
print("    -H 'X-Mock-Status: 500' \\")
print("    -d '{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}'")
