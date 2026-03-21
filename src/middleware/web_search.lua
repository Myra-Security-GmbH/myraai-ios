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
--   Leg 1 — non-streaming buffered call with web_search tool injected
--   Search — parallel Brave API calls (ngx.thread.spawn, non-blocking)
--   Leg 2  — ctx.request_body updated with tool results; upstream.run() streams it

local upstream  = require("middleware.upstream")
local search    = require("utils.search")
local providers = require("providers")
local json      = require("utils.json")

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
    local tool = ctx.is_compat and OPENAI_TOOL or ANTHROPIC_TOOL
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
    if not ws or not ws.enabled or not ws.api_key then return end

    -- Default mode is opt-in: client must send X-Web-Search: 1
    if ws.mode ~= "always" then
        local h = ngx.req.get_headers()["x-web-search"]
        if not h or h == "0" or h == "false" then return end
    end

    local provider = ctx.provider
    if not provider then return end

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

    -- ── Compat Anthropic: skip for now (request is OpenAI format but response
    --    is Anthropic format, requiring non-trivial bidirectional conversion)
    if ctx.is_compat and provider == "anthropic" then return end

    -- Remaining supported providers
    local is_anthropic = (provider == "anthropic")
    if not is_anthropic and not OPENAI_FORMAT_PROVIDERS[provider] then return end

    -- ── Leg 1: non-streaming buffered call ───────────────────────────────────
    local orig_stream = ctx.request_body.stream
    ctx.request_body.stream = false
    inject_tool(ctx)

    local body_str, status, err = upstream.call_one(ctx)
    if err or not body_str then
        ngx.log(ngx.WARN, "web_search: leg1 failed (", tostring(err), ") — passing through")
        ctx.request_body.stream = orig_stream
        ctx.raw_request_body    = json.encode(ctx.request_body)
        return
    end

    -- ── Check for tool_use ───────────────────────────────────────────────────
    local tool_calls = extract_tool_calls(body_str, is_anthropic)

    if not tool_calls then
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
    local results   = search.parallel(queries, ws.api_key, ws.max_results or 5)
    local query_str = table.concat(queries, "; ")

    ngx.log(ngx.INFO, "web_search: searched query=\"", query_str,
            "\" provider=", provider)
    ctx.log_fields.web_search_query  = query_str
    ngx.header["X-Web-Search-Query"] = query_str

    -- ── Leg 2: inject results, restore stream, fall through to upstream ───────
    inject_results(ctx, body_str, tool_calls, results, is_anthropic)
    ctx.request_body.stream = orig_stream
    ctx.raw_request_body    = json.encode(ctx.request_body)
    ctx.web_search_leg2     = true
end

return M
