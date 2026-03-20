-- tests/unit/test_cache_key.lua — unit tests for cache/key.lua
-- Run with: busted tests/unit/test_cache_key.lua

-- Stub ngx
_G.ngx = {
    now    = function() return 1700000000 end,
    log    = function() end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local key_builder = require("cache.key")

describe("cache.key", function()

    it("produces a hex sha256 string", function()
        local ctx = {
            provider     = "openai",
            model        = "gpt-4o",
            request_body = {
                model    = "gpt-4o",
                messages = {{ role = "user", content = "Hello" }},
            }
        }
        local k = key_builder.build(ctx)
        assert.is_string(k)
        assert.equal(k:sub(1, 6), "cache:")
        assert.equal(#k, 6 + 64)  -- "cache:" + 64 hex chars
    end)

    it("returns nil for streaming requests", function()
        local ctx = {
            provider     = "openai",
            model        = "gpt-4o",
            request_body = { model = "gpt-4o", stream = true,
                             messages = {{ role = "user", content = "Hi" }} },
        }
        assert.is_nil(key_builder.build(ctx))
    end)

    it("produces the same key for identical requests", function()
        local body = { model = "gpt-4o", messages = {{ role = "user", content = "Hi" }} }
        local ctx1 = { provider = "openai", model = "gpt-4o", request_body = body }
        local ctx2 = { provider = "openai", model = "gpt-4o", request_body = body }
        assert.equal(key_builder.build(ctx1), key_builder.build(ctx2))
    end)

    it("produces different keys for different models", function()
        local mk = function(model)
            return key_builder.build({
                provider     = "openai",
                model        = model,
                request_body = { model = model,
                                 messages = {{ role="user", content="Hi" }} },
            })
        end
        assert.not_equal(mk("gpt-4o"), mk("gpt-4o-mini"))
    end)

    it("ignores the 'user' field in the key", function()
        local mk = function(user)
            return key_builder.build({
                provider     = "openai",
                model        = "gpt-4o",
                request_body = { model = "gpt-4o", user = user,
                                 messages = {{ role="user", content="Hi" }} },
            })
        end
        assert.equal(mk("alice"), mk("bob"))
    end)

end)
