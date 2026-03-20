-- tests/fixtures/seed.lua — populate config.db with a test tenant for dev/testing
-- Run with: resty -I src/ tests/fixtures/seed.lua
--
-- Creates:
--   tenant:  "test-tenant"
--   gateway: "main"  (auth disabled, cache 60s, rate limit 100/min)
--   BYOK key: openai → provider key from AIG_TEST_OPENAI_KEY env
--   auth token: "test-token-1234" (printed to stdout)

package.path = package.path .. ";src/?.lua;src/?/init.lua"

-- Stub ngx for CLI context
_G.ngx = _G.ngx or {
    shared = {},
    log    = function(_, ...) io.write(table.concat({...}, " ") .. "\n") end,
    ERR    = 0, WARN = 1, INFO = 2, NOTICE = 3, DEBUG = 4,
    now    = function() return os.time() end,
    encode_base64 = require and require("mime") and require("mime").b64 or tostring,
}

-- Override AIG_CONFIG to point at the dev config
os.setenv = os.setenv or function() end
os.execute("export AIG_CONFIG=config/gateway.lua")

local cfg     = dofile("config/gateway.lua")
local sqlite  = require("storage.sqlite")
local byok    = require("auth.byok")
local crypto  = require("utils.crypto")

sqlite.init(cfg)

-- 1. Create tenant
local tenant_id = sqlite.upsert_tenant("test-tenant", "free", 10.0)
print("tenant_id = " .. tenant_id)

-- 2. Create gateway
local gw_config = {
    auth_required = false,  -- disable auth for easy testing
    cache_ttl     = 60,
    rate_limit    = { requests = 100, window_sec = 60 },
    log_payloads  = true,
}
local gateway_id = sqlite.upsert_gateway(tenant_id, "main", gw_config)
print("gateway_id = " .. gateway_id)

-- 3. Store BYOK key for OpenAI
local openai_key = os.getenv("AIG_TEST_OPENAI_KEY") or "sk-test-placeholder"
byok.store_key(gateway_id, "openai", "default", openai_key)
print("openai key stored")

-- 4. Store BYOK key for Anthropic (optional)
local anthropic_key = os.getenv("AIG_TEST_ANTHROPIC_KEY")
if anthropic_key then
    byok.store_key(gateway_id, "anthropic", "default", anthropic_key)
    print("anthropic key stored")
end

-- 5. Create an auth token
local raw_token = "test-token-1234"
local hash      = crypto.sha256_hex(raw_token)
sqlite.insert_auth_token(gateway_id, hash, {"read", "write"}, nil)
print("auth token: " .. raw_token)

print("\nExample request:")
print(string.format(
    "curl -X POST http://localhost:8080/v1/test-tenant/main/openai/v1/chat/completions \\\n" ..
    "  -H 'Content-Type: application/json' \\\n" ..
    "  -H 'x-aig-token: %s' \\\n" ..
    "  -d '{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'",
    raw_token
))
