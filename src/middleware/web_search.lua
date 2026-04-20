-- middleware/web_search.lua — server-side two-leg agentic web search loop
--
-- Enabled per gateway via gateway_config.web_search:
--   { enabled = true, api_key = "...", max_results = 5, mode = "opt-in" }
--
-- mode = "opt-in"  (default) — client must send  X-Web-Search: 1
-- mode = "always"            — applied to every request on this gateway
--
-- Supported providers (two-leg tool-use loop):
--   anthropic (native endpoint only), openai, groq, mistral, deepseek,
--   cerebras, together, fireworks, openrouter, xai, ollama
--
-- Gemini: uses native googleSearch grounding (single leg, no tool loop).
--
-- Flow:
--   Leg 1   — non-streaming buffered call with web_search tool injected
--   Search  — parallel Brave API calls (ngx.thread.spawn, non-blocking)
--   Fetch   — parallel HTTP page fetches for top-2 URLs (non-blocking)
--             emits  data: {"aig_status":"fetching","count":N}  before fetching
--   Leg 2   — ctx.request_body updated with enriched context; upstream.run() streams it

local upstream   = require("middleware.upstream")
local search     = require("utils.search")
local providers  = require("providers")
local json       = require("utils.json")
local trace      = require("utils.trace")

local FETCH_N = 2  -- max URLs to fetch per request

local M = {}

-- Providers that accept OpenAI-format tool_calls / tool role messages
-- (anything served through the compat or OpenAI-native path).
local OPENAI_FORMAT_PROVIDERS = {
    openai     = true,
    groq       = true,
    mistral    = true,
    deepseek   = true,
    cerebras   = true,
    together   = true,
    fireworks  = true,
    openrouter = true,
    xai        = true,
    ollama     = true,
    huggingface = true,
    sambanova  = true,
    nvidia     = true,
    azure      = true,
    cloudflare = true,
    cohere     = true,
}

-- ── Tool definitions ──────────────────────────────────────────────────────────

local ANTHROPIC_TOOL = {
    name        = "web_search",
    description = "Search the web for current information. Use this whenever " ..
                  "the user asks about recent events, live data, or anything " ..
                  "that may have changed since your training cutoff.",
    input_schema = {
        type       = "object",
        properties = { query = { type = "string", description = "The search query" } },
        required   = { "query" },
    },
}

local OPENAI_TOOL = {
    type = "function",
    ["function"] = {
        name        = "web_search",
        description = "Search the web for current information.",
        parameters  = {
            type       = "object",
            properties = { query = { type = "string", description = "The search query" } },
            required   = { "query" },
        },
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Inject the web_search tool into ctx.request_body (and sync raw_request_body).
local function inject_tool(ctx)
    local rb   = ctx.request_body
    rb.tools   = rb.tools or {}
    -- Use provider, not ctx.is_compat: by the time web_search runs, transform
    -- has already converted the body to the provider's native format, so the
    -- compat flag no longer reflects the current body schema.
    local tool = (ctx.provider == "anthropic") and ANTHROPIC_TOOL or OPENAI_TOOL
    for _, t in ipairs(rb.tools) do
        local name = t.name or (t["function"] and t["function"].name)
        if name == "web_search" then return end  -- already present
    end
    rb.tools[#rb.tools + 1] = tool
    ctx.raw_request_body    = json.encode(rb)
end

-- Detect tool_use in a raw Leg 1 provider response.
-- Returns array of {id, query}, or nil if no search needed.
-- response_is_anthropic: true when the provider returns Anthropic-format JSON.
local function extract_tool_calls(body_str, response_is_anthropic)
    local body = json.decode(body_str)
    if not body then return nil end

    if response_is_anthropic then
        if body.stop_reason ~= "tool_use" then return nil end
        local calls = {}
        for _, block in ipairs(body.content or {}) do
            if block.type == "tool_use" and block.name == "web_search" then
                calls[#calls + 1] = {
                    id    = block.id,
                    query = block.input and block.input.query or "",
                }
            end
        end
        return #calls > 0 and calls or nil
    else
        -- OpenAI format
        local choice = body.choices and body.choices[1]
        if not choice then return nil end
        if choice.finish_reason ~= "tool_calls" then return nil end
        local calls = {}
        for _, tc in ipairs((choice.message and choice.message.tool_calls) or {}) do
            if tc.type == "function" and tc["function"]
               and tc["function"].name == "web_search" then
                local args = json.decode(tc["function"].arguments or "{}") or {}
                calls[#calls + 1] = { id = tc.id, query = args.query or "" }
            end
        end
        return #calls > 0 and calls or nil
    end
end

-- Inject search results into ctx.request_body as Leg 2 messages.
-- Mutates ctx.request_body and updates ctx.raw_request_body.
-- inject_as_anthropic: true when ctx.request_body is Anthropic format.
local function inject_results(ctx, leg1_body_str, tool_calls, results, inject_as_anthropic)
    local leg1 = json.decode(leg1_body_str) or {}
    local rb   = ctx.request_body
    rb.messages = rb.messages or {}

    if inject_as_anthropic then
        -- Append assistant turn (leg1 content) + user tool_result turn
        local tool_results = {}
        for i, tc in ipairs(tool_calls) do
            tool_results[#tool_results + 1] = {
                type        = "tool_result",
                tool_use_id = tc.id,
                content     = results[i] or "No results found.",
            }
        end
        rb.messages[#rb.messages + 1] = { role = "assistant", content = leg1.content }
        rb.messages[#rb.messages + 1] = { role = "user",      content = tool_results }
        -- Prevent recursive search in Leg 2
        rb.tool_choice = { type = "none" }
    else
        -- Append OpenAI-format assistant message + tool role messages
        local choice        = leg1.choices and leg1.choices[1]
        local assistant_msg = choice and choice.message
        if assistant_msg then
            rb.messages[#rb.messages + 1] = assistant_msg
        end
        for i, tc in ipairs(tool_calls) do
            rb.messages[#rb.messages + 1] = {
                role         = "tool",
                tool_call_id = tc.id,
                content      = results[i] or "No results found.",
            }
        end
        -- Prevent recursive search in Leg 2.
        -- OpenAI format uses the string "none", not the object {type="none"}.
        rb.tool_choice = "none"
    end

    ctx.raw_request_body = json.encode(rb)
end

-- ── Main ─────────────────────────────────────────────────────────────────────

function M.run(ctx)
    local ws = ctx.gateway_config.web_search
    if type(ws) ~= "table" or not ws.enabled or not ws.api_key then return end

    -- Default mode is opt-in: client must send X-Web-Search: 1
    if ws.mode ~= "always" then
        local h = ngx.req.get_headers()["x-aig-web-search"]
        if not h or h == "0" or h == "false" then return end
    end

    local provider = ctx.provider
    if not provider then return end

    -- Lazy-load fetch_url here (requires resty.http, only needed when web_search is active)
    local fetch_url = require("utils.fetch_url")

    -- ── Gemini: single-leg via native googleSearch grounding ─────────────────
    -- gemini.build_request() converts a tool named "web_search" to {googleSearch:{}}
    if provider == "gemini" then
        local rb = ctx.request_body
        rb.tools = rb.tools or {}
        for _, t in ipairs(rb.tools) do
            if t.name == "web_search" then return end
        end
        rb.tools[#rb.tools + 1] = { name = "web_search" }
        ctx.raw_request_body    = json.encode(rb)
        return  -- upstream.run() handles the rest
    end

    -- Remaining supported providers
    local is_anthropic = (provider == "anthropic")
    if not is_anthropic and not OPENAI_FORMAT_PROVIDERS[provider] then return end

    -- ── Leg 1: non-streaming buffered call ───────────────────────────────────
    local orig_stream = ctx.request_body.stream
    ctx.request_body.stream = false
    inject_tool(ctx)

    trace.step(ctx, "leg1_request", {
        model    = ctx.model,
        provider = ctx.provider,
        messages = ctx.request_body.messages,
        tools    = ctx.request_body.tools,
        stream   = false,
    })

    local body_str, status, err = upstream.call_one(ctx)
    if err or not body_str then
        ngx.log(ngx.WARN, "web_search: leg1 failed (", tostring(err), ") — passing through")
        ctx.request_body.stream = orig_stream
        ctx.raw_request_body    = json.encode(ctx.request_body)
        return
    end

    trace.step(ctx, "leg1_response", {
        status       = status,
        body_preview = body_str and body_str:sub(1, 2000),
        body_len     = body_str and #body_str,
    })

    -- ── Check for tool_use ───────────────────────────────────────────────────
    local tool_calls = extract_tool_calls(body_str, is_anthropic)

    if not tool_calls then
        trace.step(ctx, "leg1_direct_answer", {
            body_preview = body_str and body_str:sub(1, 1000),
        })
        -- Model answered directly — pass through Leg 1 response, skip upstream.run()
        local provider_mod = providers.get(provider)
        if provider_mod then
            local parsed = provider_mod.parse_response and provider_mod.parse_response(body_str)
            if parsed then
                if ctx.is_compat then
                    ctx.response_body = json.encode({
                        id      = "chatcmpl-" .. (ctx.request_id or "aig"),
                        object  = "chat.completion",
                        model   = ctx.model,
                        choices = {{
                            index         = 0,
                            message       = { role = "assistant", content = parsed.content },
                            finish_reason = "stop",
                        }},
                        usage = {
                            prompt_tokens     = parsed.input_tokens,
                            completion_tokens = parsed.output_tokens,
                            total_tokens      = (parsed.input_tokens or 0) +
                                                (parsed.output_tokens or 0),
                        },
                    })
                else
                    ctx.response_body = body_str
                end
                ctx.input_tokens          = parsed.input_tokens    or 0
                ctx.output_tokens         = parsed.output_tokens   or 0
                ctx.cache_creation_tokens = parsed.cache_creation_tokens or 0
                ctx.cache_read_tokens     = parsed.cache_read_tokens     or 0
                ctx.provider_status       = status
                ctx.is_streaming          = false
                ngx.status                   = status
                ngx.header["Content-Type"]   = "application/json"
                ngx.header["X-AIG-Cache"]    = "MISS"
                ngx.header["X-AIG-Provider"] = provider
                ngx.header["X-AIG-Model"]    = ctx.model
                -- Client asked for SSE but we had to buffer Leg 1 to check for
                -- a web_search tool call. Signal send_response.lua to re-emit
                -- the buffered JSON as SSE so the client gets streaming.
                if orig_stream and ctx.is_compat then
                    ctx.buffered_needs_sse_reemit = true
                end
            end
        end
        ctx.web_search_done = true
        return
    end

    -- ── Search (parallel, non-blocking via ngx.thread.spawn) ─────────────────
    local queries = {}
    for _, tc in ipairs(tool_calls) do
        queries[#queries + 1] = tc.query
    end
    -- results is array of {text=string, urls=string[]}
    local results   = search.parallel(queries, ws.api_key, ws.max_results or 5)
    local query_str = table.concat(queries, "; ")

    trace.step(ctx, "search_result", {
        queries = queries,
        results = (function()
            local r = {}
            for i, res in ipairs(results) do
                r[i] = { text_len = #(res.text or ""), urls = res.urls }
            end
            return r
        end)(),
    })

    ngx.log(ngx.INFO, "web_search: searched query=\"", query_str,
            "\" provider=", provider)
    ctx.log_fields.web_search_query  = query_str

    -- Set response headers now (before any possible early flush below).
    -- upstream.run() → handle_*_streaming() will try to set these again but
    -- OpenResty silently ignores header assignments after the first flush.
    ngx.header["X-Web-Search-Query"] = query_str
    ngx.header["X-AIG-Provider"]     = provider
    ngx.header["X-AIG-Model"]        = ctx.model
    ngx.header["X-AIG-Cache"]        = "MISS"

    -- ── Fetch top page URLs (parallel, non-blocking) ──────────────────────────
    -- Collect the first FETCH_N unique URLs across all query results.
    -- For weather queries, prepend wttr.in which returns plain-text data that
    -- JS-rendered weather sites (weather.com, wetter.de …) cannot provide.
    local top_urls  = {}
    local seen      = {}
    -- wttr_by_result[i] = wttr.in URL injected for results[i], if any
    local wttr_by_result = {}
    for idx, tc in ipairs(tool_calls) do
        local q = (tc.query or ""):lower()
        if q:match("weather") then
            local wttr = "https://wttr.in/" .. ngx.escape_uri(tc.query) .. "?format=4"
            if not seen[wttr] then
                seen[wttr]              = true
                top_urls[#top_urls + 1] = wttr
                wttr_by_result[idx]     = wttr
            end
        end
    end
    for _, r in ipairs(results) do
        for _, u in ipairs(r.urls or {}) do
            if not seen[u] and #top_urls < FETCH_N then
                seen[u]            = true
                top_urls[#top_urls + 1] = u
            end
        end
    end

    trace.step(ctx, "fetch_attempt", { urls = top_urls })

    if orig_stream and #top_urls > 0 then
        -- Flush SSE headers + emit fetching-status event so the client can
        -- show a "fetching…" badge while pages are being downloaded.
        if not ngx.headers_sent then
            ngx.status                      = 200
            ngx.header["Content-Type"]      = "text/event-stream"
            ngx.header["Cache-Control"]     = "no-cache"
            ngx.header["X-Accel-Buffering"] = "no"
        end
        local status_evt = json.encode({ aig_status = "fetching", count = #top_urls })
        ngx.print("data: " .. status_evt .. "\n\n")
        ngx.flush(true)
    end

    if #top_urls > 0 then
        local fetched      = fetch_url.parallel(top_urls, FETCH_N)
        do
            local fetched_info = {}
            for _, f in ipairs(fetched) do
                fetched_info[#fetched_info+1] = {
                    url      = f.url,
                    ok       = f.text ~= nil,
                    text_len = f.text and #f.text or 0,
                    preview  = f.text and f.text:sub(1, 300) or nil,
                }
            end
            trace.step(ctx, "fetch_result", { fetched = fetched_info })
        end
        local text_by_url  = {}
        for _, f in ipairs(fetched) do
            if f.text then text_by_url[f.url] = f.text end
        end

        -- Augment each query's result text with the fetched page content.
        for i, r in ipairs(results) do
            local pages = {}
            -- Include wttr.in content first (plain-text, reliable for weather)
            local wttr = wttr_by_result[i]
            if wttr and text_by_url[wttr] then
                pages[#pages + 1] = "### Source: " .. wttr .. "\n\n" .. text_by_url[wttr]
            end
            for _, u in ipairs(r.urls or {}) do
                if text_by_url[u] then
                    pages[#pages + 1] = "### Source: " .. u .. "\n\n" .. text_by_url[u]
                end
            end
            if #pages > 0 then
                results[i].text = r.text
                    .. "\n\n## Page Content\n\n"
                    .. table.concat(pages, "\n\n---\n\n")
            end
        end
    end

    -- ── Leg 2: inject enriched results, restore stream, fall through ──────────
    local result_texts = {}
    for _, r in ipairs(results) do
        result_texts[#result_texts + 1] = r.text
    end
    inject_results(ctx, body_str, tool_calls, result_texts, is_anthropic)
    ctx.request_body.stream = orig_stream
    ctx.raw_request_body    = json.encode(ctx.request_body)
    ctx.web_search_leg2     = true

    trace.step(ctx, "leg2_request", {
        model    = ctx.model,
        provider = ctx.provider,
        messages = ctx.request_body.messages,
        stream   = orig_stream,
    })
end

return M
