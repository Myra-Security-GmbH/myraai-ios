-- scripts/rotate_key.lua — update a provider API key for an existing gateway
--
-- Usage:
--   AIG_CONFIG=/path/to/config/gateway.lua \
--   AIG_MASTER_KEY=your-master-key \
--   ANTHROPIC_API_KEY=sk-ant-... \
--   resty -I src/ scripts/rotate_key.lua \
--     --tenant my-company \
--     --gateway prod \
--     [--provider anthropic] \
--     [--alias default]

package.cpath = package.cpath .. ";/usr/lib/x86_64-linux-gnu/lua/5.1/?.so"

local cfg    = dofile(os.getenv("AIG_CONFIG") or "config/gateway.lua")
local sqlite = require("storage.sqlite")
local byok   = require("auth.byok")

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

local tenant_slug  = args["tenant"]   or error("--tenant required")
local gateway_slug = args["gateway"]  or error("--gateway required")
local provider     = args["provider"] or "anthropic"
local alias        = args["alias"]    or "default"

-- ---------------------------------------------------------------------------
-- Resolve new API key (flag > env var)
-- ---------------------------------------------------------------------------
local env_vars = {
    anthropic = "ANTHROPIC_API_KEY",
    openai    = "OPENAI_API_KEY",
    gemini    = "GEMINI_API_KEY",
}
local new_key = args["key"] or os.getenv(env_vars[provider] or "")
if not new_key or new_key == "" then
    local ev = env_vars[provider] or (provider:upper() .. "_API_KEY")
    error("Provide the new key via --key <value> or " .. ev .. " env var")
end

-- Validate key prefix for anthropic
if provider == "anthropic" and not new_key:match("^sk%-ant%-") then
    io.stderr:write("Warning: key does not look like an Anthropic key (expected sk-ant-...)\n")
end

-- ---------------------------------------------------------------------------
-- Look up gateway
-- ---------------------------------------------------------------------------
local gw, err = sqlite.get_gateway(tenant_slug, gateway_slug)
if not gw then
    error("Gateway not found: " .. tenant_slug .. "/" .. gateway_slug ..
          (err and (" (" .. err .. ")") or ""))
end
local gateway_id = gw.gateway_id

-- ---------------------------------------------------------------------------
-- Store the new key
-- ---------------------------------------------------------------------------
local err = byok.store_key(gateway_id, provider, alias, new_key)
if err then error("Failed to store key: " .. err) end

io.write(string.format(
    "Key updated: tenant=%s  gateway=%s  provider=%s  alias=%s\n",
    tenant_slug, gateway_slug, provider, alias))
io.write("Gateway ID: " .. gateway_id .. "\n")
