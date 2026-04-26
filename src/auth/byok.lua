-- auth/byok.lua — BYOK provider key vault
-- Decrypts stored provider API keys on demand.
-- Caches decrypted keys in state (short TTL) to avoid per-request DB + crypto.

local storage = require("storage")
local state   = require("state")
local crypto  = require("utils.crypto")
local cfg     = require("core.app_config")

local M = {}

-- Returns the plaintext API key for (gateway_id, provider, alias) or nil, err.
function M.get_key(gateway_id, provider, alias)
    alias = alias or "default"
    local state_key = "byok:" .. gateway_id .. ":" .. provider .. ":" .. alias

    -- Check short-lived decrypted cache first
    local cached = state.byok_get(state_key)
    if cached then return cached end

    -- Fetch encrypted row from storage
    local enc_key, nonce, err = storage.get_provider_key(gateway_id, provider, alias)
    if err then
        return nil, "byok storage: " .. err
    end

    -- enc_key is stored as the output of crypto.encrypt() = "b64(iv):b64(ct)"
    -- nonce is unused for CBC (IV is embedded in enc_key); kept for future GCM
    local plaintext, dec_err = crypto.decrypt(enc_key, cfg.master_key)
    if not plaintext then
        return nil, "byok decrypt: " .. tostring(dec_err)
    end

    state.byok_set(state_key, plaintext, cfg.defaults.byok_cache_ttl)
    return plaintext
end

-- Encrypt and store a provider key. Used by the admin API.
function M.store_key(gateway_id, provider, alias, plaintext_key)
    local enc, err = crypto.encrypt(plaintext_key, cfg.master_key)
    if not enc then
        return "byok encrypt: " .. tostring(err)
    end
    storage.upsert_provider_config(gateway_id, provider, alias, enc, "")
end

-- Tenant-scoped key variants (no gateway_id — for management keys like anthropic-admin).

function M.get_tenant_key(tenant_id, provider, alias)
    alias = alias or "default"
    local state_key = "byok:tenant:" .. tenant_id .. ":" .. provider .. ":" .. alias

    local cached = state.byok_get(state_key)
    if cached then return cached end

    local enc_key, nonce, err = storage.get_tenant_provider_key(tenant_id, provider, alias)
    if err then
        return nil, "byok storage: " .. err
    end

    local plaintext, dec_err = crypto.decrypt(enc_key, cfg.master_key)
    if not plaintext then
        return nil, "byok decrypt: " .. tostring(dec_err)
    end

    state.byok_set(state_key, plaintext, cfg.defaults.byok_cache_ttl)
    return plaintext
end

function M.store_tenant_key(tenant_id, provider, alias, plaintext_key)
    local enc, err = crypto.encrypt(plaintext_key, cfg.master_key)
    if not enc then
        return "byok encrypt: " .. tostring(err)
    end
    return storage.upsert_tenant_provider_config(tenant_id, provider, alias, enc, "")
end

return M
