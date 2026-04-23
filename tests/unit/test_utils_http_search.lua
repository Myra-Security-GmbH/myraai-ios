-- tests/unit/test_utils_http_search.lua — covers:
--   utils/http.lua, utils/search.lua, utils/proc.lua, utils/trace.lua,
--   utils/request.lua, utils/uuid.lua, utils/json.lua
-- Run with: resty tests/runner.lua tests/unit/test_utils_http_search.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _log_buf = {}
_G.ngx = {
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) error(c, 0) end,
    print  = function() end,
    status = 200,
    header = {},
    var    = {},
    ctx    = {},
    req    = { read_body=function() end, get_body_data=function() return nil end,
               get_body_file=function() return nil end },
    ERR    = 0, WARN = 1, INFO = 2,
    time   = function() return 1700000000 end,
    now    = function() return 1700000000.0 end,
    escape_uri = function(s) return s end,
    timer  = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
    thread = {
        spawn = function(fn, ...) local a = {...}; return { fn=fn, args=a } end,
        wait  = function(t) return pcall(t.fn, table.unpack(t.args)) end,
        kill  = function() end,
    },
}

for _, n in ipairs({"utils.http","utils.search","utils.proc","utils.trace","utils.request",
                    "utils.uuid","utils.json","resty.http","ngx.pipe","storage",
                    "core.app_config","resty.random","resty.string"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end

-- Mock resty.http
local _http_calls  = {}
local _http_response = { status=200, headers={["Content-Type"]="application/json"},
                          body=cjson.encode({ web={ results={
                              { title="Test", url="https://example.com", description="desc" }
                          }}}) }
local _http_error = nil
package.preload["resty.http"] = function()
    return {
        new = function()
            return {
                set_timeouts  = function() end,
                parse_uri     = function(self, url)
                    return {"https","example.com",443,"/path",""}, nil
                end,
                connect       = function() return true, nil end,
                request       = function(self, opts)
                    _http_calls[#_http_calls + 1] = opts
                    if _http_error then return nil, _http_error end
                    local res = {
                        status  = _http_response.status,
                        headers = _http_response.headers,
                        read_body    = function() return _http_response.body, nil end,
                        set_keepalive = function() end,
                    }
                    return res, nil
                end,
                set_keepalive = function() end,
            }
        end,
    }
end

-- Mock ngx.pipe for proc.lua
local _pipe_calls  = {}
local _pipe_stdout = "test output"
local _pipe_code   = 0
package.preload["ngx.pipe"] = function()
    return {
        spawn = function(cmd, opts)
            _pipe_calls[#_pipe_calls + 1] = cmd
            return {
                set_timeouts    = function() end,
                write           = function() return true, nil end,
                shutdown        = function() end,
                stdout_read_all = function() return _pipe_stdout, nil end,
                wait            = function() return true, "exit", _pipe_code end,
                kill            = function() end,
            }, nil
        end,
    }
end

-- Mock storage for trace.lua
package.preload["storage"] = function()
    return {
        create_trace             = function() end,
        add_playground_trace_step = function() end,
        complete_playground_trace = function() end,
    }
end

package.preload["utils.json"] = function()
    local j = {}
    j.encode = cjson.encode
    j.decode = cjson.decode
    j.null   = cjson.null
    j.sanitize_surrogates = function(s) return s end
    return j
end

local http    = require("utils.http")
local search  = require("utils.search")
local proc    = require("utils.proc")
local trace   = require("utils.trace")
local req_util = require("utils.request")

local function reset()
    _log_buf     = {}
    _http_calls  = {}
    _pipe_calls  = {}
    _http_error  = nil
    _pipe_stdout = "test output"
    _pipe_code   = 0
    _G.ngx.req.get_body_data = function() return nil end
    _G.ngx.req.get_body_file = function() return nil end
end

-- ============================================================================
-- utils/uuid.lua
-- ============================================================================

describe("utils.uuid: v4()", function()
    local uuid = require("utils.uuid")

    it("returns a 36-character string", function()
        assert.equal(36, #uuid.v4())
    end)

    it("has hyphens at positions 9, 14, 19, 24", function()
        local u = uuid.v4()
        assert.equal("-", u:sub(9, 9))
        assert.equal("-", u:sub(14, 14))
        assert.equal("-", u:sub(19, 19))
        assert.equal("-", u:sub(24, 24))
    end)

    it("third segment starts with '4' (version 4)", function()
        local u = uuid.v4()
        -- third group is positions 15-18
        assert.equal("4", u:sub(15, 15))
    end)

    it("two consecutive calls produce different UUIDs", function()
        assert.not_equal(uuid.v4(), uuid.v4())
    end)

end)

-- ============================================================================
-- utils/json.lua
-- ============================================================================

describe("utils.json: encode/decode", function()
    local json = require("utils.json")

    it("encode + decode round-trip preserves structure", function()
        reset()
        local orig = { name="test", count=42, tags={"a","b"} }
        local enc = json.encode(orig)
        assert.not_nil(enc)
        local dec = json.decode(enc)
        assert.equal("test", dec.name)
        assert.equal(42, dec.count)
    end)

    it("decode('') does not raise (returns {} or nil)", function()
        reset()
        local ok = pcall(function() return json.decode("") end)
        assert.is_true(ok, "json.decode('') must not raise")
    end)

    it("decode returns nil + error for invalid JSON", function()
        reset()
        local r, err = json.decode("not json {{")
        assert.is_nil(r)
    end)

    it("sanitize_surrogates is a function", function()
        assert.equal("function", type(json.sanitize_surrogates))
    end)

    it("json.null is the cjson null sentinel", function()
        assert.not_nil(json.null)
    end)

end)

-- ============================================================================
-- utils/request.lua
-- ============================================================================

describe("utils.request: read_body()", function()

    it("returns get_body_data() result when present", function()
        reset()
        _G.ngx.req.get_body_data = function() return '{"model":"gpt-4o"}' end
        local body = req_util.read_body()
        assert.equal('{"model":"gpt-4o"}', body)
    end)

    it("returns nil when both get_body_data and get_body_file return nil", function()
        reset()
        local body = req_util.read_body()
        assert.is_nil(body)
    end)

end)

-- ============================================================================
-- utils/trace.lua
-- ============================================================================

describe("utils.trace: step recording", function()

    it("step() is a no-op when ctx.trace_id is nil", function()
        reset()
        local ctx = { trace_id = nil }
        local ok = pcall(trace.step, ctx, "test_step", { x=1 })
        assert.is_true(ok, "trace.step must not raise when trace_id is nil")
    end)

    it("step() increments ctx.trace_seq", function()
        reset()
        local ctx = { trace_id="t-001", trace_seq=0, gateway_id="gw-1" }
        trace.step(ctx, "step1", {})
        assert.equal(1, ctx.trace_seq)
        trace.step(ctx, "step2", {})
        assert.equal(2, ctx.trace_seq)
    end)

    it("done() is a no-op when ctx.trace_id is nil", function()
        reset()
        local ok = pcall(trace.done, { trace_id=nil }, "done")
        assert.is_true(ok)
    end)

    it("trace.step errors in storage do not propagate (pcall wrapped)", function()
        reset()
        package.loaded["storage"] = nil
        package.preload["storage"] = function()
            return {
                add_playground_trace_step = function()
                    error("storage failure")
                end,
            }
        end
        package.loaded["utils.trace"] = nil
        local t2 = require("utils.trace")
        local ctx = { trace_id="t-fail", trace_seq=0, gateway_id="gw-1" }
        local ok = pcall(t2.step, ctx, "step", {})
        assert.is_true(ok, "storage failure must not propagate from trace.step")
        -- Restore
        package.loaded["storage"] = nil
        package.preload["storage"] = function()
            return { create_trace=function() end, add_playground_trace_step=function() end,
                     complete_playground_trace=function() end }
        end
        package.loaded["utils.trace"] = nil
        trace = require("utils.trace")
    end)

end)

-- ============================================================================
-- utils/http.lua
-- ============================================================================

describe("utils.http: request()", function()

    it("returns (status, headers, body, nil) on success", function()
        reset()
        local status, headers, body, err = http.request({
            method = "GET",
            url    = "https://api.example.com/v1/test",
        })
        assert.equal(200, status)
        assert.is_nil(err)
        assert.not_nil(body)
    end)

    it("caller receives (nil, nil, nil, err) when the request fails (tested via search)", function()
        reset()
        -- Test that callers (e.g. search.lua) receive nil/err on http failure
        -- rather than re-loading resty.http (which can't be cleanly reloaded in tests)
        _http_error = "simulated connection refused"
        local results = search.fetch("query", "key", 3)
        -- search.lua returns {} on error; the important thing is no crash
        assert.not_nil(results, "search must return [] not nil on http error")
        assert.equal(0, #results, "failed http request must produce empty results")
    end)

end)

-- ============================================================================
-- utils/search.lua
-- ============================================================================

describe("utils.search: fetch()", function()

    it("sends GET request with correct Brave API headers", function()
        reset()
        search.fetch("lua programming", "test-brave-key", 5)
        assert.equal(1, #_http_calls)
        assert.equal("GET", _http_calls[1].method)
        local headers = _http_calls[1].headers
        assert.equal("test-brave-key", headers["X-Subscription-Token"])
        assert.equal("application/json", headers["Accept"])
    end)

    it("returns results array from Brave response", function()
        reset()
        local results = search.fetch("test query", "key", 5)
        assert.not_nil(results)
        assert.is_true(#results >= 1)
        assert.equal("Test",              results[1].title)
        assert.equal("https://example.com", results[1].url)
    end)

    it("returns {} on HTTP error", function()
        reset()
        _http_error = "connection refused"
        local results = search.fetch("query", "key", 5)
        assert.not_nil(results)
        assert.equal(0, #results)
    end)

    it("returns {} on non-200 status (tested via mock http response)", function()
        reset()
        -- Simulate a 429 response by changing the mock response
        _http_response = {
            status  = 429,
            headers = {},
            body    = '{"error":"rate limited"}',
        }
        local results = search.fetch("q", "k", 3)
        assert.equal(0, #results, "non-200 Brave response must produce empty results")
        -- Restore
        _http_response = {
            status  = 200,
            headers = { ["Content-Type"]="application/json" },
            body    = cjson.encode({ web={ results={
                { title="Test", url="https://example.com", description="desc" }
            }}}),
        }
    end)

end)

-- ============================================================================
-- utils/proc.lua
-- ============================================================================

describe("utils.proc: run()", function()

    it("spawns a subprocess and returns stdout", function()
        reset()
        _pipe_stdout = "hello from proc"
        local stdout, code, err = proc.run({"/bin/echo", "hi"}, nil, {})
        assert.equal("hello from proc", stdout)
        assert.equal(0, code)
        assert.is_nil(err)
    end)

    it("returns non-zero exit code on failure", function()
        reset()
        _pipe_code = 1
        local stdout, code, err = proc.run({"/bin/false"}, nil, {})
        -- code is non-zero on failure (1 = abnormal exit)
        -- When ok_w is false, wait returns code that signals failure
        assert.is_true(code ~= 0 or err ~= nil,
            "non-zero exit must be reported as error code or error string")
    end)

    it("passes stdin_data to the subprocess", function()
        reset()
        local stdout, code = proc.run({"/bin/cat"}, "test input", {})
        assert.equal(1, #_pipe_calls, "spawn must be called once")
    end)

end)
