-- tests/unit/test_bugs.lua — regression tests for confirmed bugs
-- Run with: busted tests/unit/test_bugs.lua
--       or: resty tests/runner.lua tests/unit/test_bugs.lua
--
-- Each describe block targets one bug. Tests assert correct behavior and
-- therefore FAIL against the current (unfixed) code.

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    print  = function() end,
    flush  = function() end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
    },
    var = {},
    ctx = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Clear both loaded cache and preload entries so each describe block
-- gets a fresh require with its own mocks.
local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- =========================================================================
-- Bug 1  src/core/config.lua:26
-- json.decode(cached) return value is not checked. When the state backend
-- returns a corrupt/non-JSON value, json.decode returns nil and the
-- function silently returns nil instead of falling through to storage.
-- =========================================================================
describe("core.config Bug 1: corrupted cache entry silently returns nil", function()
    clear({"core.config","state","storage","utils.json","core.app_config","core.errors"})

    local storage_called = false

    package.preload["core.app_config"] = function()
        return { defaults = { config_cache_ttl = 60, cache_ttl = 0,
                              retry_count = 2,       timeout_ms = 30000 } }
    end

    -- State backend holds a corrupted (non-JSON) value
    package.preload["state"] = function()
        return {
            config_get = function() return "{{corrupted}}" end,
            config_set = function() end,
        }
    end

    -- Storage would return a valid config — should be used as fallback
    package.preload["storage"] = function()
        return {
            init        = function() end,
            get_gateway = function()
                storage_called = true
                return { cache_ttl = 10, retry_count = 1,
                         timeout_ms = 5000, log_payloads = true }, nil
            end,
        }
    end

    -- json.decode returns nil for the corrupt string
    package.preload["utils.json"] = function()
        return {
            decode = function(s)
                if s == "{{corrupted}}" then return nil, "invalid token" end
                return {}
            end,
            encode = function() return '{"ok":true}' end,
        }
    end

    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end

    local config = require("core.config")

    it("falls through to storage when cached JSON fails to decode", function()
        local result = config.get_gateway("tenant", "gw")
        -- Bug: returns nil without consulting storage.
        -- Fix: clears the bad entry and fetches from storage.
        assert.not_nil(result,
            "get_gateway should return a valid config, not nil, on a corrupt cache entry")
        assert.is_true(storage_called,
            "storage should be consulted as a fallback when cache decode fails")
    end)
end)

-- =========================================================================
-- Bug 2  src/core/config.lua:46
-- json.encode(config) return value is not checked. When encoding fails,
-- nil is silently passed to state.config_set, poisoning the cache so that
-- the next request hits Bug 1 immediately.
-- =========================================================================
describe("core.config Bug 2: json.encode failure stores nil in state backend", function()
    clear({"core.config","state","storage","utils.json","core.app_config","core.errors"})

    local cache_set_value = "sentinel"  -- overwritten by config_set

    package.preload["core.app_config"] = function()
        return { defaults = { config_cache_ttl = 60, cache_ttl = 0,
                              retry_count = 2,       timeout_ms = 30000 } }
    end

    package.preload["state"] = function()
        return {
            config_get = function() return nil end,  -- cache miss
            config_set = function(_k, v, _ttl) cache_set_value = v end,
        }
    end

    package.preload["storage"] = function()
        return {
            init        = function() end,
            get_gateway = function()
                return { cache_ttl = 10, retry_count = 1,
                         timeout_ms = 5000, log_payloads = true }, nil
            end,
        }
    end

    -- json.encode fails (e.g. config contains a non-serialisable value)
    package.preload["utils.json"] = function()
        return {
            decode = function() return { cache_ttl = 10 } end,
            encode = function() return nil, "cannot serialise userdata" end,
        }
    end

    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end

    local config = require("core.config")

    it("does not store nil in cache when json.encode fails", function()
        cache_set_value = "sentinel"
        config.get_gateway("tenant", "gw")
        -- Bug: config_set is called with nil (the failed encode result).
        -- Fix: encode failure is detected; config_set is skipped or a log is emitted.
        assert.not_nil(cache_set_value,
            "state.config_set must not be called with nil when json.encode fails")
    end)
end)

-- =========================================================================
-- Bug 3  src/middleware/upstream.lua:89
-- The streaming loop condition is:  if chunk == "" or chunk == nil
-- An OpenResty cosocket reader returns "" for a partial read with no bytes
-- and nil for EOF. Breaking on "" prematurely terminates the stream and
-- drops any SSE data that arrives in a later read.
-- =========================================================================
describe("middleware.upstream Bug 3: streaming breaks prematurely on empty-string chunk", function()
    clear({"middleware.upstream","providers","utils.http","core.errors","utils.json","auth.byok","state"})

    local printed = {}
    _G.ngx.print  = function(s) printed[#printed + 1] = s end
    _G.ngx.flush  = function() end
    _G.ngx.header = {}

    -- Reader: first call returns "" (empty read), second returns real SSE data.
    -- A correct implementation treats "" as "no bytes yet" and keeps looping.
    local function make_reader(chunks)
        local i = 0
        return function(_size)
            i = i + 1
            return chunks[i]  -- nil when exhausted = EOF
        end
    end

    package.preload["providers"] = function()
        return {
            get = function()
                return {
                    base_url        = function() return "http://mock/v1/chat" end,
                    build_headers   = function() return {} end,
                    build_request   = function() return '{"model":"x"}' end,
                    parse_sse_chunk = function() return nil end,
                }, nil
            end,
        }
    end

    package.preload["utils.http"] = function()
        local httpc = { set_keepalive = function() end }
        return {
            request = function()
                -- First chunk is empty, second is real SSE payload
                return 200, {}, make_reader({ "", 'data: {"delta":"hi"}\n\n' }), nil, httpc
            end,
        }
    end

    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end

    package.preload["utils.json"] = function()
        return { encode = function() return "{}" end,
                 decode = function() return {} end }
    end

    package.preload["state"] = function()
        local store = {}
        return {
            config_get = function(k) return store[k] end,
            config_set = function(k, v) store[k] = v end,
        }
    end

    local upstream = require("middleware.upstream")

    it("forwards SSE chunks that arrive after an empty-string read", function()
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000,
                                 provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = true },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }

        printed = {}
        upstream.run(ctx)

        local all = table.concat(printed)
        -- Bug: "" triggers break; the SSE chunk after it is never forwarded.
        -- Fix: only nil (EOF) breaks the loop; "" is treated as a non-event.
        assert.not_equal("", all,
            "SSE data chunk after an empty-string read was dropped (empty-chunk break bug)")
    end)
end)

-- =========================================================================
-- Bug 4  src/middleware/transform.lua:31,37,46
-- There is no `return` after any of the three errors.send() calls. In
-- production ngx.exit() terminates the coroutine, so this is harmless.
-- In unit-test environments that mock errors.send() without calling
-- ngx.exit(), execution continues and json.decode is called with nil,
-- causing a bad-argument crash instead of a clean, testable error path.
-- =========================================================================
describe("middleware.transform Bug 4: missing return after errors.send on empty body", function()
    clear({"middleware.transform","utils.json","providers.compat","core.errors"})

    local errors_send_calls = {}
    local decode_args       = {}

    -- Mock errors.send to NOT call ngx.exit — this is the typical unit-test
    -- setup that exposes the missing return statements.
    package.preload["core.errors"] = function()
        return {
            codes = {},
            send  = function(code, detail)
                errors_send_calls[#errors_send_calls + 1] =
                    { code = code, detail = detail }
                -- intentionally no ngx.exit() — exposes missing `return`
            end,
        }
    end

    package.preload["utils.json"] = function()
        return {
            decode = function(s)
                decode_args[#decode_args + 1] = s
                return nil
            end,
            encode = function() return "{}" end,
        }
    end

    package.preload["providers.compat"] = function()
        return {
            infer_provider = function() return nil end,
            provider_path  = function(p) return p end,
        }
    end

    local transform = require("middleware.transform")

    before_each(function()
        errors_send_calls = {}
        decode_args       = {}
    end)

    it("does not call json.decode after errors.send for a missing body", function()
        local ctx = {
            raw_request_body = "",   -- already read; empty string triggers the check
            request_body     = nil,
            is_compat        = false,
            meta             = {},
        }

        -- Wrap in pcall: with the bug the function crashes deep in nil indexing;
        -- with the fix it returns cleanly after errors.send.
        pcall(transform.run, ctx)

        -- errors.send must have been called exactly once for the empty-body case
        assert.equal(1, #errors_send_calls,
            "expected exactly one errors.send call (for empty body)")
        assert.equal("INVALID_REQUEST", errors_send_calls[1].code)

        -- Bug: execution continued past errors.send and called json.decode(nil).
        -- Fix: a `return` after errors.send prevents json.decode from being called.
        assert.equal(0, #decode_args,
            "json.decode must not be called after errors.send for an empty body " ..
            "(missing `return` in transform.lua)")
    end)
end)
