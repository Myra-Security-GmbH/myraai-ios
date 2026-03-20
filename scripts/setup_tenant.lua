-- scripts/setup_tenant.lua — create a tenant, gateway, and BYOK keys
--
-- Usage:
--   AIG_CONFIG=/path/to/config/gateway.lua \
--   AIG_MASTER_KEY=your-master-key \
--   ANTHROPIC_API_KEY=sk-ant-... \
--   resty -I src/ scripts/setup_tenant.lua \
--     --tenant my-company \
--     --gateway prod \
--     [--budget 10.0] \
--     [--no-auth]
--
-- Prints the bearer token to use in x-aig-token header.

package.cpath = package.cpath .. ";/usr/lib/x86_64-linux-gnu/lua/5.1/?.so"

local cfg     = dofile(os.getenv("AIG_CONFIG") or "config/gateway.lua")
local sqlite  = require("storage.sqlite")
local byok    = require("auth.byok")
local crypto  = require("utils.crypto")

sqlite.init(cfg)

-- ---------------------------------------------------------------------------
-- Parse args
-- ---------------------------------------------------------------------------
local args = {}
local i = 1
while i <= #arg do
    if arg[i]:sub(1,2) == "--" then
        local key = arg[i]:sub(3)
        if arg[i+1] and arg[i+1]:sub(1,2) ~= "--" then
            args[key] = arg[i+1]; i = i + 2
        else
            args[key] = true; i = i + 1
        end
    else
        i = i + 1
    end
end

local tenant_slug  = args["tenant"]  or "my-tenant"
local gateway_slug = args["gateway"] or "default"
local budget_usd   = tonumber(args["budget"])
local no_auth      = args["no-auth"] == true

-- ---------------------------------------------------------------------------
-- Create tenant + gateway
-- ---------------------------------------------------------------------------
local tenant_id = sqlite.upsert_tenant(tenant_slug, "standard", budget_usd)

local gw_config = {
    auth_required = not no_auth,
    cache_ttl     = 300,       -- 5-minute exact-match cache
    retry_count   = 2,
    timeout_ms    = 120000,    -- 2 min (Claude can be slow on long outputs)
    log_payloads  = true,
    rate_limit    = { requests = 500, window_sec = 60 },
}
if budget_usd then gw_config.budget_usd = budget_usd end

local gateway_id = sqlite.upsert_gateway(tenant_id, gateway_slug, gw_config)

-- ---------------------------------------------------------------------------
-- Store BYOK keys for each provider whose env key is set
-- ---------------------------------------------------------------------------
local providers = {
    { env = "ANTHROPIC_API_KEY", name = "anthropic" },
    { env = "OPENAI_API_KEY",    name = "openai"    },
    { env = "GEMINI_API_KEY",    name = "gemini"    },
    { env = "GROQ_API_KEY",      name = "groq"      },
    { env = "MISTRAL_API_KEY",   name = "mistral"   },
}

local stored = {}
for _, p in ipairs(providers) do
    local key = os.getenv(p.env)
    if key and key ~= "" then
        local err = byok.store_key(gateway_id, p.name, "default", key)
        if err then
            io.stderr:write("WARN: could not store " .. p.name .. " key: " .. err .. "\n")
        else
            stored[#stored + 1] = p.name
        end
    end
end

-- ---------------------------------------------------------------------------
-- Create a bearer token (unless --no-auth)
-- ---------------------------------------------------------------------------
local raw_token
if not no_auth then
    raw_token = crypto.random_hex(32)
    local hash = crypto.sha256_hex(raw_token)
    sqlite.insert_auth_token(gateway_id, hash, {"read", "write"}, nil)
end

-- ---------------------------------------------------------------------------
-- Print summary
-- ---------------------------------------------------------------------------
io.write("\n=== Tenant setup complete ===\n")
io.write(string.format("  tenant:    %s  (%s)\n", tenant_slug, tenant_id))
io.write(string.format("  gateway:   %s  (%s)\n", gateway_slug, gateway_id))
io.write(string.format("  providers: %s\n", #stored > 0 and table.concat(stored, ", ") or "(none)"))
if budget_usd then
    io.write(string.format("  budget:    $%.2f\n", budget_usd))
end
if raw_token then
    io.write(string.format("  token:     %s\n", raw_token))
end

io.write("\n=== Example requests ===\n\n")

local base = string.format("http://127.0.0.1:8081/v1/%s/%s", tenant_slug, gateway_slug)
-- Use x-api-key so examples work unchanged with the Anthropic SDK and Claude Code
local token_header = raw_token
    and string.format("  -H 'x-api-key: %s' \\\n", raw_token)
    or  ""

if #stored > 0 then
    local provider = stored[1]

    -- Native endpoint
    local path = provider == "anthropic" and "/v1/messages" or "/v1/chat/completions"
    io.write("# Native " .. provider .. " endpoint:\n")
    io.write(string.format("curl -s -X POST '%s/%s%s' \\\n", base, provider, path))
    io.write("  -H 'Content-Type: application/json' \\\n")
    io.write(token_header)

    if provider == "anthropic" then
        io.write("  -d '{\n")
        io.write('    "model": "claude-sonnet-4-6",\n')
        io.write('    "max_tokens": 256,\n')
        io.write('    "messages": [{"role": "user", "content": "Hello, Claude!"}]\n')
        io.write("  }'\n")
    else
        io.write("  -d '{\n")
        io.write('    "model": "gpt-4o-mini",\n')
        io.write('    "messages": [{"role": "user", "content": "Hello!"}]\n')
        io.write("  }'\n")
    end

    -- Compat endpoint
    io.write("\n# OpenAI-compatible unified endpoint:\n")
    io.write(string.format("curl -s -X POST '%s/compat/chat/completions' \\\n", base))
    io.write("  -H 'Content-Type: application/json' \\\n")
    io.write(token_header)
    io.write("  -d '{\n")
    if provider == "anthropic" then
        io.write('    "model": "claude-sonnet-4-6",\n')
    else
        io.write('    "model": "gpt-4o-mini",\n')
    end
    io.write('    "messages": [{"role": "user", "content": "Hello!"}]\n')
    io.write("  }'\n")

    -- Streaming (only if anthropic was stored)
    local has_anthropic = false
    for _, p in ipairs(stored) do if p == "anthropic" then has_anthropic = true end end
    if has_anthropic then
        io.write("\n# Streaming:\n")
        io.write(string.format("curl -s -N -X POST '%s/anthropic/v1/messages' \\\n", base))
        io.write("  -H 'Content-Type: application/json' \\\n")
        io.write(token_header)
        io.write("  -d '{\n")
        io.write('    "model": "claude-sonnet-4-6",\n')
        io.write('    "max_tokens": 256,\n')
        io.write('    "stream": true,\n')
        io.write('    "messages": [{"role": "user", "content": "Count to 5"}]\n')
        io.write("  }'\n")
    end
end

-- Claude Code / Anthropic SDK section
io.write("\n=== Claude Code / Anthropic SDK ===\n\n")
if raw_token then
    io.write(string.format('export ANTHROPIC_BASE_URL="%s/anthropic"\n', base))
    io.write(string.format('export ANTHROPIC_API_KEY="%s"\n', raw_token))
else
    io.write(string.format('export ANTHROPIC_BASE_URL="%s/anthropic"\n', base))
    io.write("# No auth token (gateway configured with auth_required=false)\n")
    io.write('export ANTHROPIC_API_KEY="placeholder"\n')
end
io.write("claude\n\n")
