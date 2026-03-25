-- tests/unit/test_semantic_cache.lua
-- Unit tests for cache/semantic.lua
-- Run with: resty tests/runner.lua tests/unit/test_semantic_cache.lua

-- ─── ngx stub ──────────────────────────────────────────────────────────────
local _log_calls   = {}
local _timer_calls = {}

_G.ngx = {
    log  = function(_, ...) _log_calls[#_log_calls+1] = table.concat({...}) end,
    now  = function() return 1700000000.0 end,
    WARN = 4,
    ERR  = 3,
    INFO = 2,
    timer = {
        at = function(delay, fn, ...)
            local args = {...}
            _timer_calls[#_timer_calls+1] = { delay = delay, fn = fn, args = args }
            -- Execute synchronously for testing
            fn(nil, (table.unpack or unpack)(args))
            return true, nil
        end,
    },
}

package.path = "/home/sas/work/ai-gateway/src/?.lua;" ..
               "/home/sas/work/ai-gateway/src/?/init.lua;" ..
               package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ─── module stubs ──────────────────────────────────────────────────────────

local _http_requests = {}
local _http_response = nil   -- set per-test to control embed_text return
local _http_error    = nil

package.preload["resty.http"] = function()
    return {
        new = function()
            return {
                set_timeout = function() end,
                request_uri = function(self, url, opts)
                    _http_requests[#_http_requests+1] = {
                        url     = url,
                        method  = opts.method,
                        body    = opts.body,
                        headers = opts.headers,
                    }
                    if _http_error then
                        return nil, _http_error
                    end
                    return _http_response
                end,
            }
        end,
    }
end

-- resty.sha256 stub — returns a fixed hex-decodable string
package.preload["resty.sha256"] = function()
    return {
        new = function()
            return {
                update = function() end,
                final  = function() return "fakehash" end,
            }
        end,
    }
end

-- resty.string stub
package.preload["resty.string"] = function()
    return {
        to_hex = function(s) return "hex(" .. tostring(s) .. ")" end,
    }
end

-- utils.json stub — wraps cjson
local cjson = require("cjson.safe")
package.preload["utils.json"] = function()
    return { encode = cjson.encode, decode = cjson.decode }
end

-- utils.uuid stub
package.preload["utils.uuid"] = function()
    return { v4 = function() return "test-uuid-1234" end }
end

-- storage stub — tracks calls
local _storage_calls = {}
local _candidates    = {}
local _storage_error = false

package.preload["storage"] = function()
    return {
        find_semantic_candidates = function(gw_id, model, limit)
            _storage_calls[#_storage_calls+1] = {
                fn = "find_semantic_candidates",
                gw_id = gw_id, model = model, limit = limit,
            }
            if _storage_error then error("db error") end
            return _candidates
        end,
        increment_semantic_hit = function(id)
            _storage_calls[#_storage_calls+1] = { fn = "increment_semantic_hit", id = id }
        end,
        insert_semantic_cache = function(entry)
            _storage_calls[#_storage_calls+1] = { fn = "insert_semantic_cache", entry = entry }
        end,
    }
end

-- Clear and reload module between test groups
local function reload()
    _log_calls    = {}
    _timer_calls  = {}
    _http_requests = {}
    _http_response = nil
    _http_error    = nil
    _storage_calls = {}
    _candidates    = {}
    _storage_error = false
    package.loaded["cache.semantic"] = nil
    package.loaded["storage"]        = nil
end

reload()
local sem = require("cache.semantic")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make_embed_response(vec)
    return {
        status = 200,
        body   = cjson.encode({
            data = { { embedding = vec } }
        }),
    }
end

local function ctx_with_messages(messages, gateway_id, model)
    return {
        request_body = { messages = messages },
        response_body = '{"choices":[{"message":{"content":"The answer is 42"}}]}',
        gateway_id = gateway_id or "gw-1",
        model      = model or "gpt-4o",
        cost_usd   = 0.002,
        is_streaming = false,
        log_fields = {},
    }
end

local function cfg(extra)
    local c = {
        enabled       = true,
        embedding_url = "https://api.openai.com/v1/embeddings",
        embedding_api_key = "sk-test",
        embedding_model   = "text-embedding-3-small",
        threshold         = 0.95,
        max_candidates    = 100,
        ttl               = 86400,
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

-- ============================================================================
-- cosine_similarity
-- ============================================================================

describe("cosine_similarity", function()

    it("returns 1.0 for identical vectors", function()
        local v = {1, 0, 0}
        local sim = sem._cosine_similarity(v, v)
        assert.near(1.0, sim, 1e-9)
    end)

    it("returns 0.0 for orthogonal vectors", function()
        local sim = sem._cosine_similarity({1, 0, 0}, {0, 1, 0})
        assert.near(0.0, sim, 1e-9)
    end)

    it("returns 0.0 for zero-magnitude input", function()
        local sim = sem._cosine_similarity({0, 0, 0}, {1, 2, 3})
        assert.equal(0, sim)
    end)

    it("returns expected similarity for known 3D vectors", function()
        -- [1,1,0] · [1,0,0] = 1; |[1,1,0]| = sqrt(2); |[1,0,0]| = 1
        -- sim = 1/sqrt(2) ≈ 0.7071
        local sim = sem._cosine_similarity({1, 1, 0}, {1, 0, 0})
        assert.near(0.7071, sim, 0.001)
    end)

    it("handles negative components", function()
        local sim = sem._cosine_similarity({1, 0}, {-1, 0})
        assert.near(-1.0, sim, 1e-9)
    end)

end)

-- ============================================================================
-- extract_prompt_text
-- ============================================================================

describe("extract_prompt_text", function()

    it("extracts single message", function()
        local ctx = { request_body = { messages = { {role="user", content="hello"} } } }
        assert.equal("hello", sem._extract_prompt_text(ctx))
    end)

    it("concatenates multi-turn messages with newline", function()
        local ctx = { request_body = { messages = {
            {role = "user",      content = "hi"},
            {role = "assistant", content = "hello"},
            {role = "user",      content = "how are you"},
        }}}
        local text = sem._extract_prompt_text(ctx)
        assert.equal("hi\nhello\nhow are you", text)
    end)

    it("skips empty content strings", function()
        local ctx = { request_body = { messages = {
            {role = "user", content = ""},
            {role = "user", content = "real"},
        }}}
        assert.equal("real", sem._extract_prompt_text(ctx))
    end)

    it("returns nil when request_body is nil", function()
        local ctx = { request_body = nil }
        assert.is_nil(sem._extract_prompt_text(ctx))
    end)

    it("returns nil when messages is empty", function()
        local ctx = { request_body = { messages = {} } }
        assert.is_nil(sem._extract_prompt_text(ctx))
    end)

    it("returns nil when all content fields are empty", function()
        local ctx = { request_body = { messages = {
            {role = "user", content = ""}
        }}}
        assert.is_nil(sem._extract_prompt_text(ctx))
    end)

    it("returns nil when messages key is missing", function()
        local ctx = { request_body = {} }
        assert.is_nil(sem._extract_prompt_text(ctx))
    end)

end)

-- ============================================================================
-- embed_text
-- ============================================================================

describe("embed_text", function()

    before_each(function() reload(); sem = require("cache.semantic") end)

    it("sends correct POST body and returns float array on success", function()
        _http_response = make_embed_response({0.1, 0.2, 0.3})
        local vec, err = sem._embed_text("hello world", cfg())
        assert.is_nil(err)
        assert.equal(3, #vec)
        assert.near(0.1, vec[1], 1e-9)
        assert.equal(1, #_http_requests)

        local req = _http_requests[1]
        assert.equal("https://api.openai.com/v1/embeddings", req.url)
        assert.equal("POST", req.method)

        local body = cjson.decode(req.body)
        assert.equal("text-embedding-3-small", body.model)
        assert.equal("hello world", body.input[1])
    end)

    it("includes Authorization header when api_key is set", function()
        _http_response = make_embed_response({0.5})
        sem._embed_text("x", cfg())
        local req = _http_requests[1]
        assert.equal("Bearer sk-test", req.headers["Authorization"])
    end)

    it("omits Authorization header when api_key is empty", function()
        _http_response = make_embed_response({0.5})
        sem._embed_text("x", cfg({ embedding_api_key = "" }))
        local req = _http_requests[1]
        assert.is_nil(req.headers["Authorization"])
    end)

    it("returns nil + error on HTTP transport failure", function()
        _http_error = "connection refused"
        local vec, err = sem._embed_text("x", cfg())
        assert.is_nil(vec)
        assert.is_string(err)
        assert.truthy(err:find("connection refused"))
    end)

    it("returns nil + error on non-200 status", function()
        _http_response = { status = 401, body = '{"error":"invalid key"}' }
        local vec, err = sem._embed_text("x", cfg())
        assert.is_nil(vec)
        assert.is_string(err)
        assert.truthy(err:find("401"))
    end)

    it("returns nil + error when response body is not valid JSON", function()
        _http_response = { status = 200, body = "not json" }
        local vec, err = sem._embed_text("x", cfg())
        assert.is_nil(vec)
        assert.is_string(err)
    end)

    it("returns nil + error when data array is missing", function()
        _http_response = { status = 200, body = '{"object":"list","data":[]}' }
        local vec, err = sem._embed_text("x", cfg())
        assert.is_nil(vec)
        assert.is_string(err)
    end)

end)

-- ============================================================================
-- M.check
-- ============================================================================

describe("M.check", function()

    before_each(function() reload(); sem = require("cache.semantic") end)

    it("returns nil when cfg.enabled is false", function()
        local result = sem.check(ctx_with_messages({{role="user",content="hi"}}), cfg({enabled=false}))
        assert.is_nil(result)
        assert.equal(0, #_http_requests)
    end)

    it("returns nil when cfg is nil", function()
        local result = sem.check(ctx_with_messages({{role="user",content="hi"}}), nil)
        assert.is_nil(result)
    end)

    it("returns nil when embedding_url is missing", function()
        local result = sem.check(
            ctx_with_messages({{role="user",content="hi"}}),
            cfg({ embedding_url = nil }))
        assert.is_nil(result)
    end)

    it("returns nil (fail-open) when embed_text fails", function()
        _http_error = "timeout"
        local result = sem.check(
            ctx_with_messages({{role="user",content="hi"}}),
            cfg())
        assert.is_nil(result)
        -- Should log a WARN
        assert.truthy(#_log_calls > 0)
    end)

    it("returns nil when no candidates in storage", function()
        _http_response = make_embed_response({1, 0, 0})
        _candidates = {}
        local result = sem.check(
            ctx_with_messages({{role="user",content="hello"}}),
            cfg())
        assert.is_nil(result)
    end)

    it("returns nil when best similarity is below threshold", function()
        _http_response = make_embed_response({1, 0, 0})
        _candidates = {
            {
                id            = "cand-1",
                embedding     = cjson.encode({0, 1, 0}),  -- orthogonal → sim = 0
                response_body = '{"choices":[]}',
                cost_usd      = 0.001,
            }
        }
        local result = sem.check(
            ctx_with_messages({{role="user",content="hello"}}),
            cfg({ threshold = 0.95 }))
        assert.is_nil(result)
    end)

    it("returns hit when best similarity meets threshold", function()
        local vec = {1, 0, 0}
        _http_response = make_embed_response(vec)
        _candidates = {
            {
                id            = "cand-hit",
                embedding     = cjson.encode(vec),  -- identical → sim = 1.0
                response_body = '{"choices":[{"message":{"content":"cached!"}}]}',
                cost_usd      = 0.005,
            }
        }
        local result = sem.check(
            ctx_with_messages({{role="user",content="hello"}}),
            cfg({ threshold = 0.95 }))
        assert.not_nil(result)
        assert.near(1.0, result.similarity, 1e-9)
        assert.equal('{"choices":[{"message":{"content":"cached!"}}]}', result.response_body)
        assert.near(0.005, result.cost_usd, 1e-9)
    end)

    it("picks best candidate when multiple exist", function()
        local query = {1, 0, 0}
        local far   = {0, 1, 0}  -- orthogonal

        _http_response = make_embed_response(query)
        _candidates = {
            {
                id            = "far",
                embedding     = cjson.encode(far),
                response_body = "far response",
                cost_usd      = 0.001,
            },
            {
                id            = "close",
                embedding     = cjson.encode({1, 0, 0}),  -- identical
                response_body = "close response",
                cost_usd      = 0.002,
            },
        }

        local result = sem.check(
            ctx_with_messages({{role="user",content="q"}}),
            cfg({ threshold = 0.95 }))
        assert.not_nil(result)
        assert.equal("close response", result.response_body)
    end)

    it("calls find_semantic_candidates with correct gateway_id and model", function()
        _http_response = make_embed_response({1, 0, 0})
        _candidates = {}
        local ctx = ctx_with_messages({{role="user",content="hi"}}, "gw-test", "claude-3-5")
        sem.check(ctx, cfg())
        assert.equal(1, #_storage_calls)
        local call = _storage_calls[1]
        assert.equal("find_semantic_candidates", call.fn)
        assert.equal("gw-test", call.gw_id)
        assert.equal("claude-3-5", call.model)
    end)

    it("increments hit counter on cache hit", function()
        local vec = {1, 0, 0}
        _http_response = make_embed_response(vec)
        _candidates = {
            { id = "hit-id", embedding = cjson.encode(vec),
              response_body = "r", cost_usd = 0 }
        }
        sem.check(ctx_with_messages({{role="user",content="hi"}}), cfg())
        local found = false
        for _, c in ipairs(_storage_calls) do
            if c.fn == "increment_semantic_hit" then
                found = true
                assert.equal("hit-id", c.id)
            end
        end
        assert.truthy(found, "increment_semantic_hit was not called")
    end)

    it("skips candidates with wrong embedding length", function()
        _http_response = make_embed_response({1, 0, 0})
        _candidates = {
            {
                id            = "wrong-dim",
                embedding     = cjson.encode({1, 0}),  -- 2D vs 3D query
                response_body = "r",
                cost_usd      = 0,
            }
        }
        local result = sem.check(
            ctx_with_messages({{role="user",content="hi"}}),
            cfg({ threshold = 0.5 }))
        assert.is_nil(result)
    end)

end)

-- ============================================================================
-- M.store_async
-- ============================================================================

describe("M.store_async", function()

    before_each(function() reload(); sem = require("cache.semantic") end)

    it("does nothing when enabled is false", function()
        sem.store_async(
            ctx_with_messages({{role="user",content="hi"}}),
            cfg({ enabled = false }))
        assert.equal(0, #_timer_calls)
    end)

    it("does nothing when embedding_url is missing", function()
        local no_url_cfg = { enabled = true }  -- no embedding_url key
        sem.store_async(
            ctx_with_messages({{role="user",content="hi"}}),
            no_url_cfg)
        assert.equal(0, #_timer_calls)
    end)

    it("does nothing for streaming responses", function()
        local ctx = ctx_with_messages({{role="user",content="hi"}})
        ctx.is_streaming = true
        sem.store_async(ctx, cfg())
        assert.equal(0, #_timer_calls)
    end)

    it("does nothing when response_body is nil", function()
        local ctx = ctx_with_messages({{role="user",content="hi"}})
        ctx.response_body = nil
        sem.store_async(ctx, cfg())
        assert.equal(0, #_timer_calls)
    end)

    it("fires timer with delay 0", function()
        _http_response = make_embed_response({0.1, 0.2, 0.3})
        sem.store_async(
            ctx_with_messages({{role="user",content="hi"}}),
            cfg())
        assert.equal(1, #_timer_calls)
        assert.equal(0, _timer_calls[1].delay)
    end)

    it("calls insert_semantic_cache with correct fields", function()
        _http_response = make_embed_response({0.1, 0.2, 0.3})
        local ctx = ctx_with_messages({{role="user",content="What is AI?"}}, "gw-store", "gpt-4o-mini")
        ctx.cost_usd = 0.007
        sem.store_async(ctx, cfg())

        local insert_call = nil
        for _, c in ipairs(_storage_calls) do
            if c.fn == "insert_semantic_cache" then insert_call = c end
        end
        assert.not_nil(insert_call, "insert_semantic_cache was not called")
        local entry = insert_call.entry
        assert.equal("gw-store",     entry.gateway_id)
        assert.equal("gpt-4o-mini", entry.model)
        assert.near(0.007,           entry.cost_usd, 1e-9)
        assert.is_string(entry.id)
        assert.is_string(entry.embedding)
        assert.is_string(entry.prompt_hash)
        assert.truthy(type(entry.created_at) == "number", "created_at should be number")
        assert.truthy(type(entry.expires_at) == "number", "expires_at should be number")
        assert.truthy(entry.expires_at > entry.created_at)
    end)

    it("sets expires_at = created_at + ttl", function()
        _http_response = make_embed_response({0.5})
        local ctx = ctx_with_messages({{role="user",content="ttl test"}})
        sem.store_async(ctx, cfg({ ttl = 3600 }))

        local insert_call = nil
        for _, c in ipairs(_storage_calls) do
            if c.fn == "insert_semantic_cache" then insert_call = c end
        end
        assert.not_nil(insert_call)
        local entry = insert_call.entry
        assert.equal(entry.created_at + 3600, entry.expires_at)
    end)

    it("does not throw when embed_text fails (fail-open)", function()
        _http_error = "timeout"
        -- Should not raise
        assert.has_no.errors(function()
            sem.store_async(
                ctx_with_messages({{role="user",content="hi"}}),
                cfg())
        end)
        -- No insert should have happened
        for _, c in ipairs(_storage_calls) do
            assert.not_equal("insert_semantic_cache", c.fn)
        end
    end)

    it("does not throw when storage insert fails (fail-open)", function()
        _http_response = make_embed_response({0.1})
        _storage_error = true
        assert.has_no.errors(function()
            sem.store_async(
                ctx_with_messages({{role="user",content="hi"}}),
                cfg())
        end)
    end)

    it("stores the response_body from context", function()
        _http_response = make_embed_response({0.1})
        local ctx = ctx_with_messages({{role="user",content="q"}})
        ctx.response_body = '{"choices":[{"message":{"content":"stored!"}}]}'
        sem.store_async(ctx, cfg())

        local insert_call = nil
        for _, c in ipairs(_storage_calls) do
            if c.fn == "insert_semantic_cache" then insert_call = c end
        end
        assert.not_nil(insert_call)
        assert.equal(ctx.response_body, insert_call.entry.response_body)
    end)

end)
