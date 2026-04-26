-- middleware/url_fetch.lua — two-leg tool-use loop for fetching web page URLs
--
-- Injects a `fetch_url` tool so the model can request page content when a user
-- shares a URL.  Flow is identical to web_search.lua:
--   Leg 1  — non-streaming buffered call with fetch_url tool injected
--   Fetch  — parallel HTTP page fetches via utils/fetch_url (with SSRF guard)
--   Leg 2  — enriched context injected, falls through to upstream.run() for streaming
--
-- Supported providers: anthropic (native) + all OpenAI-format providers.
-- Gemini is skipped (needs native grounding, no standard tool-use loop).
--
-- Skip condition: if web_search already handled the request (ctx.web_search_done
-- or ctx.web_search_leg2), this middleware is a no-op.

local upstream   = require("middleware.upstream")
local providers  = require("providers")
local json       = require("utils.json")
local trace      = require("utils.trace")

local M = {}

-- Providers that accept OpenAI-format tool_calls / tool role messages
local OPENAI_FORMAT_PROVIDERS = {
    openai      = true,
    groq        = true,
    mistral     = true,
    deepseek    = true,
    cerebras    = true,
    together    = true,
    fireworks   = true,
    openrouter  = true,
    xai         = true,
    ollama      = true,
    huggingface = true,
    sambanova   = true,
    nvidia      = true,
    azure       = true,
    cloudflare  = true,
    cohere      = true,
}

-- ── Tool definitions ─────────────────────────────────────────────────────────

local ANTHROPIC_TOOL = {
    name        = "fetch_url",
    description = "Fetch the content of a web page URL and return it as plain text. "
               .. "Use this when the user shares a URL and asks you to read, summarize, "
               .. "or analyze its content.",
    input_schema = {
        type       = "object",
        properties = {
            url = {
                type        = "string",
                description = "The full URL to fetch (must start with http:// or https://)",
            },
        },
        required = { "url" },
    },
}

local OPENAI_TOOL = {
    type = "function",
    ["function"] = {
        name        = "fetch_url",
        description = "Fetch the content of a web page URL and return it as plain text. "
                   .. "Use this when the user shares a URL and asks you to read, summarize, "
                   .. "or analyze its content.",
        parameters  = {
            type       = "object",
            properties = {
                url = {
                    type        = "string",
                    description = "The full URL to fetch (must start with http:// or https://)",
                },
            },
            required = { "url" },
        },
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function inject_tool(ctx)
    local rb   = ctx.request_body
    rb.tools   = rb.tools or {}
    local tool = (ctx.provider == "anthropic") and ANTHROPIC_TOOL or OPENAI_TOOL
    for _, t in ipairs(rb.tools) do
        local name = t.name or (t["function"] and t["function"].name)
        if name == "fetch_url" then return end  -- already present
    end
    rb.tools[#rb.tools + 1] = tool
    ctx.raw_request_body    = json.encode(rb)
end

-- Extract fetch_url tool calls from a Leg 1 response.
-- Returns array of {id, url}, or nil if the model didn't call fetch_url.
local function extract_tool_calls(body_str, is_anthropic)
    local body = json.decode(body_str)
    if not body then return nil end

    if is_anthropic then
        if body.stop_reason ~= "tool_use" then return nil end
        local calls = {}
        for _, block in ipairs(body.content or {}) do
            if block.type == "tool_use" and block.name == "fetch_url" then
                calls[#calls + 1] = {
                    id  = block.id,
                    url = block.input and block.input.url or "",
                }
            end
        end
        return #calls > 0 and calls or nil
    else
        local choice = body.choices and body.choices[1]
        if not choice then return nil end
        if choice.finish_reason ~= "tool_calls" then return nil end
        local calls = {}
        for _, tc in ipairs((choice.message and choice.message.tool_calls) or {}) do
            if tc.type == "function" and tc["function"]
               and tc["function"].name == "fetch_url" then
                local args = json.decode(tc["function"].arguments or "{}") or {}
                calls[#calls + 1] = { id = tc.id, url = args.url or "" }
            end
        end
        return #calls > 0 and calls or nil
    end
end

-- Inject fetch results into ctx.request_body as Leg 2 messages.
local function inject_results(ctx, leg1_body_str, tool_calls, results, is_anthropic)
    local leg1 = json.decode(leg1_body_str) or {}
    local rb   = ctx.request_body
    rb.messages = rb.messages or {}

    if is_anthropic then
        local tool_results = {}
        for i, tc in ipairs(tool_calls) do
            tool_results[#tool_results + 1] = {
                type        = "tool_result",
                tool_use_id = tc.id,
                content     = results[i] or "Failed to fetch URL.",
            }
        end
        rb.messages[#rb.messages + 1] = { role = "assistant", content = leg1.content }
        rb.messages[#rb.messages + 1] = { role = "user",      content = tool_results }
        rb.tool_choice = { type = "none" }
    else
        local choice        = leg1.choices and leg1.choices[1]
        local assistant_msg = choice and choice.message
        if assistant_msg then
            rb.messages[#rb.messages + 1] = assistant_msg
        end
        for i, tc in ipairs(tool_calls) do
            rb.messages[#rb.messages + 1] = {
                role         = "tool",
                tool_call_id = tc.id,
                content      = results[i] or "Failed to fetch URL.",
            }
        end
        rb.tool_choice = "none"
    end

    ctx.raw_request_body = json.encode(rb)
end

-- ── Main ─────────────────────────────────────────────────────────────────────

-- Only activate Leg 1 when the ORIGINAL user message contains a URL.
-- Skip injected context (file reads, continuations) to avoid false positives
-- from URLs inside project knowledge files.
local function last_user_message_has_url(ctx)
    local msgs = ctx.request_body and ctx.request_body.messages
    if not msgs or #msgs == 0 then return false end
    -- Walk backwards to find the last user message that is NOT injected context
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        if m.role == "user" then
            local text = type(m.content) == "string" and m.content or ""
            if type(m.content) == "table" then
                -- content-block array: concatenate text blocks
                for _, block in ipairs(m.content) do
                    if type(block) == "table" and block.text then
                        text = text .. " " .. block.text
                    elseif type(block) == "string" then
                        text = text .. " " .. block
                    end
                end
            end
            -- Skip injected context messages: file-read injections from the
            -- frontend start with "## File:" or "Continue"; these often contain
            -- URLs from project knowledge files that shouldn't trigger url_fetch.
            if text:match("^## File:") or text:match("^Continue$") then
                -- This is injected context — check the NEXT user message up
            else
                return text:match("https?://[%w%.%-]+%.[%w]+") ~= nil
            end
        end
    end
    return false
end

function M.run(ctx)
    -- Skip if web_search or tool_loop already handled this request
    if ctx.web_search_done or ctx.web_search_leg2 then return end
    if ctx.tool_loop_done or ctx.tool_loop_leg2 then return end

    local provider = ctx.provider
    if not provider then return end

    local is_anthropic = (provider == "anthropic")
    if not is_anthropic and not OPENAI_FORMAT_PROVIDERS[provider] then return end

    -- Only proceed if the user's message contains a URL
    if not last_user_message_has_url(ctx) then
        ngx.log(ngx.DEBUG, "url_fetch: skipped — no URL in last user message")
        return
    end
    ngx.log(ngx.NOTICE, "url_fetch: ACTIVATING — URL detected in last user message")

    local fetch_url = require("utils.fetch_url")

    -- ── Leg 1: non-streaming buffered call ───────────────────────────────────
    local orig_stream = ctx.request_body.stream
    ctx.request_body.stream = false
    inject_tool(ctx)

    trace.step(ctx, "url_fetch_leg1_request", {
        model    = ctx.model,
        provider = ctx.provider,
        tools    = ctx.request_body.tools,
        stream   = false,
    })

    local body_str, status, err = upstream.call_one(ctx)
    if err or not body_str then
        ngx.log(ngx.WARN, "url_fetch: leg1 failed (", tostring(err), ") — passing through")
        ctx.request_body.stream = orig_stream
        ctx.raw_request_body    = json.encode(ctx.request_body)
        return
    end

    trace.step(ctx, "url_fetch_leg1_response", {
        status       = status,
        body_preview = body_str and body_str:sub(1, 2000),
    })

    -- ── Check for fetch_url tool_use ─────────────────────────────────────────
    local tool_calls = extract_tool_calls(body_str, is_anthropic)

    if not tool_calls then
        -- Model answered directly — pass through Leg 1 response
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
                ctx.input_tokens             = parsed.input_tokens             or 0
                ctx.output_tokens            = parsed.output_tokens            or 0
                ctx.cache_creation_tokens    = parsed.cache_creation_tokens    or 0
                ctx.cache_creation_1h_tokens = parsed.cache_creation_1h_tokens or 0
                ctx.cache_read_tokens        = parsed.cache_read_tokens        or 0
                ctx.cache_deletion_tokens    = parsed.cache_deletion_tokens    or 0
                ctx.provider_status       = status
                ctx.is_streaming          = false
                ngx.status                   = status
                ngx.header["Content-Type"]   = "application/json"
                ngx.header["X-AIG-Cache"]    = "MISS"
                ngx.header["X-AIG-Provider"] = provider
                ngx.header["X-AIG-Model"]    = ctx.model
                -- Client asked for SSE but we had to buffer Leg 1 to check for
                -- fetch_url tool calls. Signal send_response.lua to re-emit
                -- the buffered JSON as SSE so the client gets streaming.
                if orig_stream and ctx.is_compat then
                    ctx.buffered_needs_sse_reemit = true
                end
            end
        end
        ctx.url_fetch_done = true
        return
    end

    -- ── Fetch URLs (parallel, non-blocking) ──────────────────────────────────
    local urls = {}
    for _, tc in ipairs(tool_calls) do
        urls[#urls + 1] = tc.url
    end

    ngx.log(ngx.INFO, "url_fetch: fetching ", #urls, " URL(s): ",
            table.concat(urls, ", "))

    -- Set response headers before any flush
    ngx.header["X-AIG-Provider"] = provider
    ngx.header["X-AIG-Model"]    = ctx.model
    ngx.header["X-AIG-Cache"]    = "MISS"

    -- Emit SSE fetching status event for streaming clients
    if orig_stream and #urls > 0 then
        if not ngx.headers_sent then
            ngx.status                      = 200
            ngx.header["Content-Type"]      = "text/event-stream"
            ngx.header["Cache-Control"]     = "no-cache"
            ngx.header["X-Accel-Buffering"] = "no"
        end
        local status_evt = json.encode({ aig_status = "fetching_url", count = #urls })
        ngx.print("data: " .. status_evt .. "\n\n")
        ngx.flush(true)
    end

    trace.step(ctx, "url_fetch_attempt", { urls = urls })

    local MAX_FETCHES_PER_TURN = 5
    if #urls > MAX_FETCHES_PER_TURN then
        ngx.log(ngx.WARN, "url_fetch: capping ", #urls, " requested URLs to ", MAX_FETCHES_PER_TURN)
        urls = {table.unpack(urls, 1, MAX_FETCHES_PER_TURN)}
    end
    local fetched = fetch_url.parallel(urls, #urls)

    trace.step(ctx, "url_fetch_result", {
        fetched = (function()
            local r = {}
            for _, f in ipairs(fetched) do
                r[#r + 1] = {
                    url      = f.url,
                    ok       = f.text ~= nil,
                    text_len = f.text and #f.text or 0,
                }
            end
            return r
        end)(),
    })

    -- Build result strings for each tool call
    local result_texts = {}
    local text_by_url = {}
    for _, f in ipairs(fetched) do
        if f.text then text_by_url[f.url] = f.text end
    end
    for _, tc in ipairs(tool_calls) do
        local text = text_by_url[tc.url]
        if text then
            result_texts[#result_texts + 1] = "Content of " .. tc.url .. ":\n\n" .. text
        else
            result_texts[#result_texts + 1] = "Failed to fetch " .. tc.url
                .. " (the page may be unavailable, require authentication, or block automated access)."
        end
    end

    -- ── Leg 2: inject results, restore stream, fall through to upstream ──────
    inject_results(ctx, body_str, tool_calls, result_texts, is_anthropic)
    ctx.request_body.stream = orig_stream
    ctx.raw_request_body    = json.encode(ctx.request_body)
    ctx.url_fetch_leg2      = true

    trace.step(ctx, "url_fetch_leg2_request", {
        model    = ctx.model,
        provider = ctx.provider,
        stream   = orig_stream,
    })
end

return M
