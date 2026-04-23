-- tests/unit/test_web_search_units.lua
-- Unit tests for utils/search.lua and middleware/web_search.lua.
--
-- search.lua: parallel return type, thread-failure fill.
-- web_search.lua: result_texts extraction, aig_status emission,
--                 web_search_done flag, non-streaming skips status emit.

_G.ngx = {
    log            = function() end,
    print          = function() end,
    flush          = function() end,
    escape_uri     = function(s) return s end,
    headers_sent   = false,
    status         = 200,
    header         = {},
    req            = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
    thread = {
        spawn = function(fn, ...)
            return { fn = fn, args = {...} }
        end,
        wait  = function(t) return pcall(t.fn, unpack(t.args)) end,
        kill  = function(t) t.killed = true end,
    },
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- search.parallel: return type and thread-failure fill
-- ─────────────────────────────────────────────────────────────────────────────

describe("search.parallel — return type is {text, urls}[]", function()

    local function make_http_mock(results_by_query)
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    local q = opts.url:match("q=([^&]+)") or ""
                    local rows = results_by_query[q] or {}
                    local items = {}
                    for _, r in ipairs(rows) do
                        items[#items+1] = string.format(
                            '{"title":"%s","url":"%s","description":"%s"}',
                            r.title or "", r.url or "", r.snippet or "")
                    end
                    local body = '{"web":{"results":[' .. table.concat(items, ",") .. ']}}'
                    return 200, {}, body, nil
                end,
            }
        end
    end

    before_each(function()
        clear({"utils.search", "utils.http", "utils.json"})
    end)

    it("single query returns table with text and urls fields", function()
        make_http_mock({
            ["hello"] = {
                { title = "Example", url = "http://example.com/", snippet = "An example site" },
            }
        })
        local search = require("utils.search")
        local out = search.parallel({"hello"}, "key", 5)
        assert.equal(1, #out)
        assert.is_string(out[1].text)
        assert(type(out[1].urls) == "table", "urls should be a table")
        assert.equal(1, #out[1].urls)
        assert.equal("http://example.com/", out[1].urls[1])
    end)

    it("multiple queries return one entry per query", function()
        make_http_mock({
            ["q1"] = {{ title = "A", url = "http://a.com/", snippet = "site a" }},
            ["q2"] = {{ title = "B", url = "http://b.com/", snippet = "site b" }},
        })
        local search = require("utils.search")
        local out = search.parallel({"q1", "q2"}, "key", 5)
        assert.equal(2, #out)
        assert.equal("http://a.com/", out[1].urls[1])
        assert.equal("http://b.com/", out[2].urls[1])
    end)

    it("no results → text contains 'No results' and urls is empty", function()
        make_http_mock({})
        local search = require("utils.search")
        local out = search.parallel({"unknown"}, "key", 5)
        assert.equal(1, #out)
        assert(out[1].text:find("No results"), "should say No results")
        assert.equal(0, #out[1].urls)
    end)

    it("urls list does not include empty-string URLs", function()
        make_http_mock({
            ["q"] = {
                { title = "A", url = "http://a.com/", snippet = "a" },
                { title = "B", url = "",              snippet = "b" },  -- empty url
            }
        })
        local search = require("utils.search")
        local out = search.parallel({"q"}, "key", 5)
        assert.equal(1, #out[1].urls, "empty URL should be excluded")
        assert.equal("http://a.com/", out[1].urls[1])
    end)

    it("empty queries list returns empty table", function()
        make_http_mock({})
        local search = require("utils.search")
        local out = search.parallel({}, "key", 5)
        assert.equal(0, #out)
    end)

    it("thread failure fills remaining entries with empty results", function()
        make_http_mock({
            ["q1"] = {{ title = "A", url = "http://a.com/", snippet = "a" }},
        })
        -- Override thread mock so the 2nd wait errors
        local wait_calls = 0
        _G.ngx.thread.wait = function(t)
            wait_calls = wait_calls + 1
            if wait_calls == 1 then return false, "network error" end
            return pcall(t.fn, unpack(t.args))
        end
        local search = require("utils.search")
        local out = search.parallel({"q1", "q2", "q3"}, "key", 5)
        -- After first wait fails we break; all entries should still exist
        assert.equal(3, #out, "should have entry for every query (filled with empty on failure)")
        -- First entry: failed → empty
        assert(out[1].text:find("No results") or out[1].text == "", "failed query should yield no-results text")
        assert.equal(0, #out[1].urls)
        -- Entries 2 and 3: killed + filled with empty
        for i = 2, 3 do
            assert(out[i] ~= nil, "entry " .. i .. " should not be nil")
            assert(type(out[i].text) == "string", "entry " .. i .. " text should be string")
            assert(type(out[i].urls) == "table", "entry " .. i .. " urls should be table")
        end
        -- Restore normal thread.wait
        _G.ngx.thread.wait = function(t) return pcall(t.fn, unpack(t.args)) end
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- web_search.run: core logic via M.run with full mocks
-- ─────────────────────────────────────────────────────────────────────────────

-- Build minimal ctx that satisfies web_search.run
local function make_ctx(overrides)
    local ctx = {
        provider        = "ollama",
        model           = "ollama/qwen2.5:3b",
        gateway_id      = "gw1",
        is_compat       = true,
        log_fields      = {},
        gateway_config  = {
            web_search = { enabled = true, api_key = "brave-key", max_results = 3 },
        },
        request_body    = {
            stream   = true,
            messages = {{ role = "user", content = "hello" }},
        },
        raw_request_body = "{}",
        provider_api_key = "key",
    }
    for k, v in pairs(overrides or {}) do ctx[k] = v end
    ctx.raw_request_body = require("utils.json").encode(ctx.request_body)
    return ctx
end

-- Preload all heavy dependencies so we control behaviour.
local function setup_web_search_mocks(opts)
    opts = opts or {}

    -- upstream.call_one returns leg1 body (OpenAI format with tool_calls or not)
    package.preload["middleware.upstream"] = function()
        return {
            call_one = function(ctx)
                return opts.leg1_body or
                    '{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Direct answer"}}]}',
                    200, nil
            end,
            run = function(ctx) end,
        }
    end

    -- search.parallel returns {text, urls}[] with preset URLs
    package.preload["utils.search"] = function()
        return {
            parallel = function(queries, api_key, n)
                local out = {}
                for i, q in ipairs(queries) do
                    out[i] = {
                        text = "Results for " .. q,
                        urls = opts.result_urls or { "http://result" .. i .. ".com/" },
                    }
                end
                return out
            end,
        }
    end

    -- fetch_url.parallel returns {url, text}[]
    package.preload["utils.fetch_url"] = function()
        return {
            parallel = function(urls, n)
                local out = {}
                for i, u in ipairs(urls) do
                    out[i] = { url = u, text = opts.fetched_text or ("Page content for " .. u) }
                end
                return out
            end,
        }
    end

    -- providers stub (for "model answered directly" path)
    package.preload["providers"] = function()
        return {
            get = function(name)
                return {
                    parse_response = function(body)
                        return { content = "Direct answer", input_tokens = 5, output_tokens = 3,
                                 cache_creation_tokens = 0, cache_read_tokens = 0 }
                    end,
                }
            end,
        }
    end
end

describe("web_search.run — web search disabled / not opted in", function()
    before_each(function()
        clear({"middleware.web_search","middleware.upstream","utils.search",
               "utils.fetch_url","providers","utils.json"})
        setup_web_search_mocks()
    end)

    it("returns immediately when web_search not configured", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search = nil
        ws.run(ctx)
        assert.is_nil(ctx.web_search_done)
        assert.is_nil(ctx.web_search_leg2)
    end)

    it("returns immediately when client does not send X-Aig-Web-Search: 1 (opt-in mode)", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        -- req headers has no x-aig-web-search
        ws.run(ctx)
        assert.is_nil(ctx.web_search_done)
    end)

    it("proceeds when X-Aig-Web-Search: 1 is set", function()
        _G.ngx.req.get_headers = function() return { ["x-aig-web-search"] = "1" } end
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ws.run(ctx)
        -- leg1 has no tool_calls → web_search_done
        assert.is_true(ctx.web_search_done)
        _G.ngx.req.get_headers = function() return {} end
    end)

    it("proceeds when mode=always without header", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.is_true(ctx.web_search_done)
    end)
end)

describe("web_search.run — model answers directly (no tool_use)", function()
    before_each(function()
        clear({"middleware.web_search","middleware.upstream","utils.search",
               "utils.fetch_url","providers","utils.json"})
        setup_web_search_mocks({
            -- Leg 1 response: finish_reason=stop (no tool_calls)
            leg1_body = '{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"42"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}',
        })
    end)

    it("sets ctx.web_search_done = true", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.is_true(ctx.web_search_done)
    end)

    it("does not set ctx.web_search_leg2", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.is_nil(ctx.web_search_leg2)
    end)
end)

describe("web_search.run — tool_use detected → Leg 2 path", function()
    local TOOL_CALLS_BODY = [[{
        "choices": [{
            "finish_reason": "tool_calls",
            "message": {
                "role": "assistant",
                "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": { "name": "web_search", "arguments": "{\"query\":\"latest news\"}" }
                }]
            }
        }]
    }]]

    before_each(function()
        clear({"middleware.web_search","middleware.upstream","utils.search",
               "utils.fetch_url","providers","utils.json"})
        _G.ngx.header         = {}
        _G.ngx.headers_sent   = false
        setup_web_search_mocks({ leg1_body = TOOL_CALLS_BODY })
    end)

    it("sets ctx.web_search_leg2 = true", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.is_true(ctx.web_search_leg2)
    end)

    it("does not set ctx.web_search_done", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.is_nil(ctx.web_search_done)
    end)

    it("injects tool results into ctx.request_body messages", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        local msgs = ctx.request_body.messages
        -- Should have appended: original user msg, assistant tool_calls msg, tool result msg
        assert(#msgs >= 2, "messages should have been extended for Leg 2")
        -- Last message should be tool role
        local last = msgs[#msgs]
        assert.equal("tool", last.role)
    end)

    it("result_texts include fetched page content when URLs available", function()
        local injected_content = nil
        -- Capture what gets written into messages
        local orig_upstream = package.preload["middleware.upstream"]
        package.preload["middleware.upstream"] = function()
            return {
                call_one = function(ctx) return TOOL_CALLS_BODY, 200, nil end,
                run      = function(ctx) end,
            }
        end

        setup_web_search_mocks({
            leg1_body    = TOOL_CALLS_BODY,
            result_urls  = { "http://news.example.com/" },
            fetched_text = "Breaking: important story today",
        })

        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)

        -- Find the tool result message and check its content contains fetched text
        local found = false
        for _, msg in ipairs(ctx.request_body.messages) do
            if msg.role == "tool" and type(msg.content) == "string" then
                if msg.content:find("Page Content") and
                   msg.content:find("Breaking") then
                    found = true
                end
            end
        end
        assert.is_true(found, "tool result should contain fetched page content")
    end)

    it("sets X-Web-Search-Query header from search query", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        assert.not_nil(ngx.header["X-Web-Search-Query"])
        assert(ngx.header["X-Web-Search-Query"]:find("latest news"),
               "X-Web-Search-Query should contain the search term")
    end)

    it("emits aig_status SSE event when streaming and URLs found", function()
        local printed = {}
        _G.ngx.print = function(s) printed[#printed+1] = s end

        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ctx.request_body.stream = true
        ws.run(ctx)

        local emitted = table.concat(printed, "")
        assert(emitted:find("aig_status"), "should emit aig_status event")
        assert(emitted:find("fetching"),    "aig_status value should be 'fetching'")
        assert(emitted:find("count"),       "should include count field")
    end)

    it("does NOT emit aig_status when request is non-streaming", function()
        local printed = {}
        _G.ngx.print = function(s) printed[#printed+1] = s end

        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ctx.request_body.stream = false
        ws.run(ctx)

        local emitted = table.concat(printed, "")
        assert(not emitted:find("aig_status"),
               "should NOT emit aig_status for non-streaming requests")
    end)

    it("does NOT emit aig_status when Brave returns no URLs", function()
        clear({"middleware.web_search","middleware.upstream","utils.search",
               "utils.fetch_url","providers","utils.json"})
        setup_web_search_mocks({ leg1_body = TOOL_CALLS_BODY, result_urls = {} })

        local printed = {}
        _G.ngx.print = function(s) printed[#printed+1] = s end

        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ctx.request_body.stream = true
        ws.run(ctx)

        local emitted = table.concat(printed, "")
        assert(not emitted:find("aig_status"),
               "should NOT emit aig_status when no URLs to fetch")
    end)

    it("restores original stream flag on ctx.request_body after run", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ctx.request_body.stream = true
        ws.run(ctx)
        assert.is_true(ctx.request_body.stream,
                       "stream flag should be restored to original value")
    end)

    it("sets tool_choice=none on request body to prevent recursive search", function()
        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)
        -- For compat (is_compat=true), tool_choice should be string "none"
        assert.equal("none", ctx.request_body.tool_choice)
    end)
end)

describe("web_search.run — Gemini single-leg path", function()
    before_each(function()
        clear({"middleware.web_search","middleware.upstream","utils.search",
               "utils.fetch_url","providers","utils.json"})
        setup_web_search_mocks()
    end)

    it("injects web_search tool and returns early (no leg1 call)", function()
        local leg1_called = false
        package.preload["middleware.upstream"] = function()
            return {
                call_one = function() leg1_called = true; return "{}", 200, nil end,
                run = function() end,
            }
        end

        local ws = require("middleware.web_search")
        local ctx = make_ctx()
        ctx.provider = "gemini"
        ctx.gateway_config.web_search.mode = "always"
        ws.run(ctx)

        assert.is_false(leg1_called, "Gemini path should not call upstream.call_one")
        local has_tool = false
        for _, t in ipairs(ctx.request_body.tools or {}) do
            if t.name == "web_search" then has_tool = true end
        end
        assert.is_true(has_tool, "Gemini path should inject web_search tool")
    end)
end)
