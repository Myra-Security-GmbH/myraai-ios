-- tests/unit/test_routing_engine.lua
-- Run with: busted tests/unit/test_routing_engine.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = {},
    shared = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Mock storage and state
-- Clear any stale cached modules from earlier test files in the same runner process
for _, n in ipairs({"routing.engine","storage","state","utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["storage"] = function()
    return {
        init = function() end,
        get_routing_rules = function(gw_id)
            -- Return fixture rules
            return {
                {
                    priority   = 10,
                    conditions = {{ field = "model", op = "prefix", value = "gpt" }},
                    actions    = { provider = "openai", model = "gpt-4o-mini" },
                    enabled    = 1,
                },
                {
                    priority   = 5,
                    conditions = {{ field = "model", op = "prefix", value = "claude" }},
                    actions    = {
                        provider  = "anthropic",
                        model     = "claude-haiku-4-5-20251001",
                        fallbacks = {{ provider = "openai", model = "gpt-4o-mini" }},
                    },
                    enabled    = 1,
                },
            }
        end,
    }
end

package.preload["state"] = function()
    local store = {}
    return {
        config_get = function(k) return store[k] end,
        config_set = function(k, v) store[k] = v end,
    }
end

local engine = require("routing.engine")

describe("routing.engine", function()

    local function ctx(model)
        return {
            gateway_id = "gw1",
            provider   = "openai",
            model      = model,
            meta       = {},
        }
    end

    it("matches gpt prefix → openai", function()
        local actions = engine.evaluate(ctx("gpt-4o"))
        assert.not_nil(actions)
        assert.equal("openai", actions.provider)
        assert.equal("gpt-4o-mini", actions.model)
    end)

    it("matches claude prefix → anthropic with fallback", function()
        local actions = engine.evaluate(ctx("claude-3-opus"))
        assert.not_nil(actions)
        assert.equal("anthropic", actions.provider)
        assert.equal(1, #actions.fallbacks)
        assert.equal("openai", actions.fallbacks[1].provider)
    end)

    it("returns nil when no rule matches", function()
        local actions = engine.evaluate(ctx("some-unknown-model"))
        assert.is_nil(actions)
    end)

end)
