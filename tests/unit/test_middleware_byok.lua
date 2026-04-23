-- tests/unit/test_middleware_byok.lua — src/middleware/byok.lua + src/auth/byok.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_byok.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local _log_buf = {}
local _exited  = nil

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

_G.ngx = {
    encode_base64  = _real_encode_base64,
    decode_base64  = _real_decode_base64,
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function() end,
    status = 200,
    header = {},
    var    = { http_x_aig_byok_alias = nil },
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"middleware.byok","auth.byok","providers","core.errors",
                    "storage","state","utils.crypto","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return { master_key = "test-master-key", defaults = { byok_cache_ttl = 300 } }
end

-- Provider registry: ollama → requires_key=false; all others need a key
local _providers_registry = {}
package.preload["providers"] = function()
    return {
        registry_entry = function(name)
            return _providers_registry[name]
        end,
    }
end

package.preload["core.errors"] = function()
    return {
        send = function(code, detail) error(code, 0) end,
        codes = {},
    }
end

-- Storage mock: holds encrypted keys
local _key_store = {}  -- {gateway_id, provider, alias} → enc_key
package.preload["storage"] = function()
    return {
        get_provider_key = function(gw_id, provider, alias)
            local k = gw_id .. ":" .. provider .. ":" .. alias
            if _key_store[k] then return _key_store[k], nil, nil end
            return nil, nil, "not found"
        end,
        upsert_provider_config = function(gw_id, provider, alias, enc, nonce)
            _key_store[gw_id .. ":" .. provider .. ":" .. alias] = enc
        end,
    }
end

-- State mock: byok cache
local _byok_cache = {}
package.preload["state"] = function()
    return {
        byok_get = function(k) return _byok_cache[k] end,
        byok_set = function(k, v, ttl) _byok_cache[k] = v end,
    }
end

-- Use real crypto for BYOK encrypt/decrypt
package.loaded["utils.crypto"] = nil
local crypto = require("utils.crypto")

local function reset()
    _log_buf    = {}
    _exited     = nil
    _key_store  = {}
    _byok_cache = {}
    _providers_registry = {}
    _G.ngx.var.http_x_aig_byok_alias = nil
    _G.ngx.ctx = {}
end

local function make_ctx(provider)
    return {
        gateway_id     = "gw-test",
        provider       = provider or "openai",
    }
end

local byok_mw   = require("middleware.byok")
local byok_vault = require("auth.byok")

-- ============================================================================
-- middleware/byok.lua: skip when provider doesn't require a key
-- ============================================================================

describe("middleware.byok: skip for key-free providers", function()

    it("skips key lookup when registry_entry.requires_key == false (e.g. ollama)", function()
        reset()
        _providers_registry["ollama"] = { requires_key = false }
        local ctx = make_ctx("ollama")
        local ok = pcall(byok_mw.run, ctx)
        assert.is_true(ok)
        assert.is_nil(ctx.provider_api_key,
            "provider_api_key must remain nil for key-free providers")
    end)

    it("proceeds to key lookup when provider requires a key (no registry entry)", function()
        reset()
        -- No registry entry → defaults to requiring a key
        -- Seed the key so it doesn't fail
        local enc = crypto.encrypt("sk-test123", "test-master-key")
        _key_store["gw-test:openai:default"] = enc
        local ctx = make_ctx("openai")
        local ok = pcall(byok_mw.run, ctx)
        assert.is_true(ok)
        assert.equal("sk-test123", ctx.provider_api_key)
    end)

end)

-- ============================================================================
-- middleware/byok.lua: key retrieval and alias
-- ============================================================================

describe("middleware.byok: key retrieval", function()

    it("sets ctx.provider_api_key on successful key lookup", function()
        reset()
        local enc = crypto.encrypt("sk-secret-key", "test-master-key")
        _key_store["gw-test:anthropic:default"] = enc
        local ctx = make_ctx("anthropic")
        local ok = pcall(byok_mw.run, ctx)
        assert.is_true(ok)
        assert.equal("sk-secret-key", ctx.provider_api_key)
    end)

    it("uses x-aig-byok-alias header as alias when present", function()
        reset()
        _G.ngx.var.http_x_aig_byok_alias = "prod"
        local enc = crypto.encrypt("sk-prod-key", "test-master-key")
        _key_store["gw-test:openai:prod"] = enc
        local ctx = make_ctx("openai")
        local ok = pcall(byok_mw.run, ctx)
        assert.is_true(ok)
        assert.equal("sk-prod-key", ctx.provider_api_key)
    end)

    it("sends INTERNAL error when key is not found in storage", function()
        reset()
        -- No key seeded
        local ctx = make_ctx("openai")
        local ok, err = pcall(byok_mw.run, ctx)
        assert.is_false(ok)
        assert.equal("INTERNAL", tostring(err))
    end)

end)

-- ============================================================================
-- auth/byok.lua: vault operations
-- ============================================================================

describe("auth.byok: vault get_key()", function()

    it("returns decrypted key from storage", function()
        reset()
        local enc = crypto.encrypt("plaintext-api-key", "test-master-key")
        _key_store["gw-v:openai:default"] = enc
        local key, err = byok_vault.get_key("gw-v", "openai", "default")
        assert.is_nil(err)
        assert.equal("plaintext-api-key", key)
    end)

    it("caches decrypted key in state after first retrieval", function()
        reset()
        local enc = crypto.encrypt("cached-key", "test-master-key")
        _key_store["gw-c:gemini:default"] = enc
        byok_vault.get_key("gw-c", "gemini", "default")
        local cache_entry = _byok_cache["byok:gw-c:gemini:default"]
        assert.not_nil(cache_entry, "key must be cached in state after first retrieval")
        assert.equal("cached-key", cache_entry)
    end)

    it("returns cached key on second call without hitting storage", function()
        reset()
        _byok_cache["byok:gw-k:azure:default"] = "from-cache"
        -- storage has nothing for this key
        local key, err = byok_vault.get_key("gw-k", "azure", "default")
        assert.is_nil(err)
        assert.equal("from-cache", key)
    end)

    it("returns nil + error string when storage has no key", function()
        reset()
        local key, err = byok_vault.get_key("gw-miss", "bedrock", "default")
        assert.is_nil(key)
        assert.not_nil(err)
        assert(tostring(err):find("byok") or tostring(err):find("not found"),
            "error should describe the failure: " .. tostring(err))
    end)

end)

describe("auth.byok: vault store_key()", function()

    it("encrypts and upserts the key in storage", function()
        reset()
        local err = byok_vault.store_key("gw-s", "openai", "new-alias", "my-api-key")
        assert.is_nil(err, "store_key must not return an error")
        local stored_enc = _key_store["gw-s:openai:new-alias"]
        assert.not_nil(stored_enc, "key must be stored after store_key()")
        -- Verify we can decrypt it back
        local dec, dec_err = crypto.decrypt(stored_enc, "test-master-key")
        assert.is_nil(dec_err)
        assert.equal("my-api-key", dec)
    end)

end)
