-- tests/unit/test_middleware_tenant.lua — unit tests for src/middleware/tenant.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_tenant.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local _exited_code = nil
local _error_code  = nil

_G.ngx = {
    log    = function() end,
    exit   = function(c) _exited_code = c; error(c, 0) end,
    var    = { uri = "/" },
    ctx    = {},
    status = 200,
    header = {},
    ERR = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"middleware.tenant","core.config","core.errors","core.app_config","storage","state","utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return { defaults = { cache_ttl=60, retry_count=2, timeout_ms=30000,
                          config_cache_ttl=60, prompt_caching={enabled=true},
                          context_compaction={enabled=false} } }
end

package.preload["state"] = function()
    local cache = {}
    return {
        config_get = function(k) return cache[k] end,
        config_set = function(k, v) cache[k] = v end,
    }
end

local _gw_db = {}
package.preload["storage"] = function()
    return {
        get_gateway = function(tenant_slug, gateway_slug)
            local key = tenant_slug .. "/" .. gateway_slug
            if _gw_db[key] then return _gw_db[key], nil end
            return nil, "not_found"
        end,
        init = function() end,
    }
end

package.preload["utils.json"] = function()
    local cjson = require("cjson.safe")
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

package.preload["core.errors"] = function()
    return {
        send = function(code, detail)
            _error_code = code
            error(code, 0)
        end,
    }
end

local function reset()
    _exited_code = nil
    _error_code  = nil
    _G.ngx.ctx   = {}
    _G.ngx.var.uri = "/"
    _gw_db       = {}
end

local function add_gateway(tenant, gateway, config)
    local key = tenant .. "/" .. gateway
    _gw_db[key] = config or {
        tenant_id  = "tn-" .. tenant,
        gateway_id = "gw-" .. gateway,
        config     = {},
    }
end

-- Reload tenant middleware after stubs are in place
local tenant = require("middleware.tenant")

-- ============================================================================
-- URI parsing
-- ============================================================================

describe("middleware.tenant: URI parsing", function()

    it("parses /v1/acme/main/openai/chat/completions correctly", function()
        reset()
        add_gateway("acme", "main")
        _G.ngx.var.uri = "/v1/acme/main/openai/chat/completions"
        local ctx = {}
        local ok = pcall(tenant.run, ctx)
        assert.is_true(ok)
        assert.equal("acme",               ctx.tenant_slug)
        assert.equal("main",               ctx.gateway_slug)
        assert.equal("openai",             ctx.provider)
        assert.equal("/chat/completions",  ctx.provider_path)
        assert.is_false(ctx.is_compat,     "is_compat must be false for openai")
    end)

    it("sets is_compat=true for the 'compat' provider", function()
        reset()
        add_gateway("acme", "main")
        _G.ngx.var.uri = "/v1/acme/main/compat/chat/completions"
        local ctx = {}
        local ok = pcall(tenant.run, ctx)
        assert.is_true(ok)
        assert.equal("compat", ctx.provider)
        assert.is_true(ctx.is_compat)
    end)

    it("sets tenant_id and gateway_id from config", function()
        reset()
        _gw_db["acme/prod"] = {
            tenant_id  = "tn-uuid-123",
            gateway_id = "gw-uuid-456",
            config     = {},
        }
        _G.ngx.var.uri = "/v1/acme/prod/anthropic/v1/messages"
        local ctx = {}
        local ok = pcall(tenant.run, ctx)
        assert.is_true(ok)
        assert.equal("tn-uuid-123", ctx.tenant_id)
        assert.equal("gw-uuid-456", ctx.gateway_id)
    end)

    it("sets provider_path to empty string when no path after provider", function()
        reset()
        add_gateway("t", "g")
        _G.ngx.var.uri = "/v1/t/g/openai"
        local ctx = {}
        local ok = pcall(tenant.run, ctx)
        assert.is_true(ok)
        assert.equal("", ctx.provider_path)
    end)

end)

-- ============================================================================
-- Provider whitelist
-- ============================================================================

describe("middleware.tenant: provider whitelist", function()

    local known = {"openai","anthropic","gemini","bedrock","mistral",
                   "groq","cohere","deepseek","xai","compat"}

    for _, prov in ipairs(known) do
        local p = prov
        it("accepts provider: " .. p, function()
            reset()
            add_gateway("t", "g")
            _G.ngx.var.uri = "/v1/t/g/" .. p .. "/v1/stuff"
            local ctx = {}
            local ok = pcall(tenant.run, ctx)
            assert.is_true(ok, p .. " must be accepted")
        end)
    end

    it("sends INVALID_REQUEST for unknown provider", function()
        reset()
        _G.ngx.var.uri = "/v1/t/g/fakeprovider/chat"
        local ctx = {}
        local ok, err = pcall(tenant.run, ctx)
        assert.is_false(ok)
        assert.equal("INVALID_REQUEST", tostring(err))
    end)

end)

-- ============================================================================
-- Error paths
-- ============================================================================

describe("middleware.tenant: error paths", function()

    it("sends INVALID_REQUEST for URI not starting with /v1/", function()
        reset()
        _G.ngx.var.uri = "/api/acme/main/openai/chat"
        local ctx = {}
        local ok, err = pcall(tenant.run, ctx)
        assert.is_false(ok)
        assert.equal("INVALID_REQUEST", tostring(err))
    end)

    it("sends INVALID_REQUEST for URI with too few segments", function()
        reset()
        _G.ngx.var.uri = "/v1/acme/main"
        local ctx = {}
        local ok, err = pcall(tenant.run, ctx)
        assert.is_false(ok)
        assert.equal("INVALID_REQUEST", tostring(err))
    end)

    it("sends TENANT_NOT_FOUND when gateway not in storage", function()
        reset()
        -- no gateway seeded
        _G.ngx.var.uri = "/v1/noexist/noexist/openai/chat"
        local ctx = {}
        local ok, err = pcall(tenant.run, ctx)
        assert.is_false(ok)
        assert.equal("TENANT_NOT_FOUND", tostring(err))
    end)

    it("attaches gateway_config table with tenant_id and gateway_id to ctx", function()
        reset()
        _gw_db["myco/prod"] = {
            tenant_id  = "tn-myco-999",
            gateway_id = "gw-prod-888",
        }
        _G.ngx.var.uri = "/v1/myco/prod/openai/v1/chat/completions"
        local ctx = {}
        local ok = pcall(tenant.run, ctx)
        assert.is_true(ok)
        assert.not_nil(ctx.gateway_config)
        assert.equal("tn-myco-999", ctx.tenant_id)
        assert.equal("gw-prod-888", ctx.gateway_id)
    end)

end)
