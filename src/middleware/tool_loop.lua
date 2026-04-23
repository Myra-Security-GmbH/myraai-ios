-- middleware/tool_loop.lua — server-side tool orchestration loop
--
-- Replaces the fragile client-side tool handling with a single server-side loop.
-- Handles: read_file, write_file, fetch_url, web_search, and MCP tools.
--
-- Flow (like OpenAI's runTools / Vercel AI SDK maxSteps):
--   1. Determine which tools are available based on request context
--   2. If no tools → return immediately (normal streaming via upstream)
--   3. Inject tools into the request
--   4. LOOP up to MAX_ROUNDS:
--      a. Buffered call to provider
--      b. If no tool calls → final answer → set ctx.response_body → return
--      c. Execute each tool server-side
--      d. Emit SSE status events for progress
--      e. Inject results into messages → loop again
--   5. Last iteration: restore streaming, fall through to upstream for final leg

local json       = require("utils.json")
local trace      = require("utils.trace")
local storage    = require("storage")

local M = {}

local MAX_TOOL_ROUNDS = 10

-- Providers that support the two-leg tool-use loop
local SUPPORTED_PROVIDERS = {
    anthropic   = true,
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
    vllm        = true,
}

-- ── Tool definitions (Anthropic + OpenAI format) ─────────────────────────────

local function make_tool(name, description, properties, required_fields)
    return {
        anthropic = {
            name         = name,
            description  = description,
            input_schema = {
                type       = "object",
                properties = properties,
                required   = required_fields,
            },
        },
        openai = {
            type = "function",
            ["function"] = {
                name        = name,
                description = description,
                parameters  = {
                    type       = "object",
                    properties = properties,
                    required   = required_fields,
                },
            },
        },
    }
end

local TOOL_DEFS = {
    read_file = make_tool(
        "read_file",
        "Read the content of a file from the project knowledge base. Use when you need to access a file the user mentions.",
        { filename = { type = "string", description = "The filename to read" } },
        { "filename" }
    ),
    write_file = make_tool(
        "write_file",
        "Create or update a file in the project knowledge base. Use when the user asks you to create, update, or save a file.",
        {
            filename = { type = "string", description = "The filename to create or update" },
            content  = { type = "string", description = "The full file content" },
        },
        { "filename", "content" }
    ),
    fetch_url = make_tool(
        "fetch_url",
        "Fetch the content of a web page URL and return it as plain text. Use when the user shares a URL and asks you to read, summarize, or analyze its content.",
        { url = { type = "string", description = "The full URL to fetch (https://...)" } },
        { "url" }
    ),
    web_search = make_tool(
        "web_search",
        "Search the web for current information. Use whenever the user asks about recent events, live data, or anything that may have changed since your training cutoff.",
        { query = { type = "string", description = "The search query" } },
        { "query" }
    ),
}

-- ── Tool injection ───────────────────────────────────────────────────────────

local function inject_tools(ctx, tool_names, mcp_tools)
    local rb = ctx.request_body
    rb.tools = rb.tools or {}
    local is_anthropic = (ctx.provider == "anthropic")

    -- Inject gateway tools
    for _, name in ipairs(tool_names) do
        local def = TOOL_DEFS[name]
        if def then
            -- Check if already present
            local found = false
            for _, t in ipairs(rb.tools) do
                local tname = t.name or (t["function"] and t["function"].name)
                if tname == name then found = true; break end
            end
            if not found then
                rb.tools[#rb.tools + 1] = is_anthropic and def.anthropic or def.openai
            end
        end
    end

    -- Inject MCP tools (already in OpenAI format from the header)
    if mcp_tools then
        for _, t in ipairs(mcp_tools) do
            local tname = t.name or (t["function"] and t["function"].name)
            local found = false
            for _, existing in ipairs(rb.tools) do
                local ename = existing.name or (existing["function"] and existing["function"].name)
                if ename == tname then found = true; break end
            end
            if not found then
                if is_anthropic then
                    -- Convert OpenAI format to Anthropic
                    local fn = t["function"] or {}
                    rb.tools[#rb.tools + 1] = {
                        name         = fn.name or tname,
                        description  = fn.description or "",
                        input_schema = fn.parameters or { type = "object", properties = {} },
                    }
                else
                    rb.tools[#rb.tools + 1] = t
                end
            end
        end
    end

    ctx.raw_request_body = json.encode(rb)
end

-- ── Extract tool calls from response ─────────────────────────────────────────

local function extract_tool_calls(body_str, is_anthropic)
    local body = json.decode(body_str)
    if not body then return nil end

    if is_anthropic then
        if body.stop_reason ~= "tool_use" then return nil end
        local calls = {}
        for _, block in ipairs(body.content or {}) do
            if block.type == "tool_use" then
                calls[#calls + 1] = {
                    id    = block.id,
                    name  = block.name,
                    input = block.input or {},
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
            if tc.type == "function" and tc["function"] then
                local args = json.decode(tc["function"].arguments or "{}") or {}
                calls[#calls + 1] = {
                    id    = tc.id,
                    name  = tc["function"].name,
                    input = args,
                }
            end
        end
        return #calls > 0 and calls or nil
    end
end

-- ── Inject tool results into messages ────────────────────────────────────────

local function inject_results(ctx, leg_body_str, tool_calls, results, is_anthropic)
    local leg = json.decode(leg_body_str) or {}
    local rb = ctx.request_body
    rb.messages = rb.messages or {}

    if is_anthropic then
        local tool_results = {}
        for i, tc in ipairs(tool_calls) do
            tool_results[#tool_results + 1] = {
                type        = "tool_result",
                tool_use_id = tc.id,
                content     = results[i] or "Tool execution failed.",
            }
        end
        rb.messages[#rb.messages + 1] = { role = "assistant", content = leg.content }
        rb.messages[#rb.messages + 1] = { role = "user",      content = tool_results }
    else
        local choice = leg.choices and leg.choices[1]
        local assistant_msg = choice and choice.message
        if assistant_msg then
            rb.messages[#rb.messages + 1] = assistant_msg
        end
        for i, tc in ipairs(tool_calls) do
            rb.messages[#rb.messages + 1] = {
                role         = "tool",
                tool_call_id = tc.id,
                content      = results[i] or "Tool execution failed.",
            }
        end
    end

    ctx.raw_request_body = json.encode(rb)
end

-- ── Tool executors ───────────────────────────────────────────────────────────

local function execute_read_file(ctx, input)
    local project_id = ctx.project_id
    if not project_id then
        ngx.log(ngx.WARN, "tool_loop: read_file no project context")
        return "Error: no project context"
    end
    -- Accept "filename" or "path" — models occasionally use the wrong field name
    local filename = input.filename or input.path
    if not filename or filename == "" then
        ngx.log(ngx.WARN, "tool_loop: read_file no filename, input=", json.encode(input))
        return "Error: filename required"
    end

    local files = storage.get_project_knowledge_text(project_id)
    local fname_lower = filename:lower()
    for _, f in ipairs(files) do
        if f.filename:lower() == fname_lower
           or f.filename:lower():match("/" .. fname_lower:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "$") then
            local text = f.extracted_text or ""
            ngx.log(ngx.NOTICE, "tool_loop: read_file ok filename=", f.filename,
                " chars=", #text, " project=", project_id)
            return "## Content of " .. f.filename .. "\n\n" .. text
        end
    end

    -- File not found — list available files
    local available = {}
    for _, f in ipairs(files) do available[#available + 1] = f.filename end
    ngx.log(ngx.WARN, "tool_loop: read_file not found filename=", filename,
        " project=", project_id, " available=", table.concat(available, ", "))
    return "File not found: " .. filename .. ". Available files: " .. table.concat(available, ", ")
end

local function execute_write_file(ctx, input)
    local project_id = ctx.project_id
    if not project_id then return "Error: no project context" end
    local filename = input.filename
    local content  = input.content
    if not filename or filename == "" then return "Error: filename required" end
    if not content then return "Error: content required" end

    local ext = filename:match("%.([^%.]+)$") or ""
    local mime_map = {
        html = "text/html", htm = "text/html", css = "text/css",
        js = "text/javascript", ts = "text/typescript", py = "text/x-python",
        sh = "text/x-sh", sql = "text/x-sql", lua = "text/x-lua",
        json = "application/json", xml = "text/xml", md = "text/markdown",
        yaml = "text/yaml", yml = "text/yaml", txt = "text/plain",
    }

    local ok, err = storage.upsert_project_knowledge({
        project_id     = project_id,
        filename       = filename,
        content_type   = mime_map[ext:lower()] or "text/plain",
        size_bytes     = #content,
        extracted_text = content,
        created_by     = ctx.user_id or "system",
    })

    if ok then
        ngx.log(ngx.NOTICE, "tool_loop: write_file ok filename=", filename,
            " chars=", #content, " project=", project_id)
        return "File saved: " .. filename .. " (" .. #content .. " bytes)"
    else
        ngx.log(ngx.ERR, "tool_loop: write_file failed filename=", filename,
            " err=", tostring(err))
        return "Error saving file: " .. tostring(err)
    end
end

local function execute_fetch_url(ctx, input)
    local fetch_url = require("utils.fetch_url")
    local url = input.url
    if not url or url == "" then return "Error: url required" end

    ngx.log(ngx.NOTICE, "tool_loop: fetch_url url=", url)
    local text = fetch_url.fetch(url)
    if text then
        return "## Content of " .. url .. "\n\n" .. text
    else
        return "Failed to fetch " .. url .. " (the page may be unavailable, require authentication, or block automated access)."
    end
end

local function execute_web_search(ctx, input)
    local search_mod = require("utils.search")
    local fetch_url  = require("utils.fetch_url")
    local query = input.query
    if not query or query == "" then return "Error: query required" end

    local ws = ctx.gateway_config.web_search
    local api_key = ws and ws.api_key
    if not api_key then return "Error: web search not configured on this gateway" end

    ngx.log(ngx.NOTICE, "tool_loop: web_search query=", query)
    local results = search_mod.parallel({ query }, api_key, ws.max_results or 5)
    local result = results[1]
    if not result or not result.text then return "No results found for: " .. query end

    -- Fetch top 2 URLs
    local top_urls = {}
    for _, u in ipairs(result.urls or {}) do
        if #top_urls < 2 then top_urls[#top_urls + 1] = u end
    end
    if #top_urls > 0 then
        local fetched = fetch_url.parallel(top_urls, 2)
        local pages = {}
        for _, f in ipairs(fetched) do
            if f.text then
                pages[#pages + 1] = "### Source: " .. f.url .. "\n\n" .. f.text
            end
        end
        if #pages > 0 then
            result.text = result.text .. "\n\n## Page Content\n\n" .. table.concat(pages, "\n\n---\n\n")
        end
    end

    ctx.log_fields = ctx.log_fields or {}
    ctx.log_fields.web_search_query = query
    return result.text
end

local function execute_mcp_tool(ctx, tool_call)
    -- Find MCP connector ID from tool name
    local mcp_tools = ctx.mcp_tools_map or {}
    local entry = mcp_tools[tool_call.name]
    if not entry then
        return "Error: MCP tool '" .. tool_call.name .. "' not found in any connector"
    end

    -- Validate connector_id to prevent path traversal into arbitrary admin API routes
    if not entry.connector_id:match("^[%w%-]+$") then
        ngx.log(ngx.WARN, "tool_loop: invalid connector_id=", tostring(entry.connector_id))
        return "Error: invalid MCP connector identifier"
    end

    local httpc = require("resty.http").new()
    httpc:set_timeout(30000)

    -- Call admin API internally with the user's session cookie
    local admin_port = 443
    local admin_host = os.getenv("AIG_ADMIN_CORS_ORIGIN") or "https://ai-api-admin.myra.eu"
    local base = admin_host:match("^https?://([^/]+)")

    local res, err = httpc:request_uri(
        "https://" .. base .. "/admin/v1/mcp/" .. entry.connector_id .. "/call",
        {
            method  = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Cookie"]       = ngx.var.http_cookie or "",
            },
            body       = json.encode({
                jsonrpc = "2.0",
                id      = 1,
                method  = "tools/call",
                params  = { name = tool_call.name, arguments = tool_call.input },
            }),
            ssl_verify = true,
        }
    )

    if not res then
        ngx.log(ngx.ERR, "tool_loop: mcp_call failed tool=", tool_call.name, " err=", tostring(err))
        return "Error calling MCP tool: " .. tostring(err)
    end

    local body = json.decode(res.body)
    if body and body.result then
        return type(body.result) == "string" and body.result or json.encode(body.result)
    elseif body and body.error then
        return "MCP error: " .. (body.error.message or json.encode(body.error))
    else
        return res.body or "Empty response from MCP tool"
    end
end

-- Dispatch a tool call to the right executor
local TOOL_EXECUTORS = {
    read_file  = execute_read_file,
    write_file = execute_write_file,
    fetch_url  = execute_fetch_url,
    web_search = execute_web_search,
}

local function execute_tool(ctx, tool_call)
    local executor = TOOL_EXECUTORS[tool_call.name]
    if executor then
        return executor(ctx, tool_call.input)
    else
        -- Try MCP
        return execute_mcp_tool(ctx, tool_call)
    end
end

-- Public: called by upstream.lua's streaming and buffered tool loops
M.execute_tool      = execute_tool
M.extract_tool_calls = extract_tool_calls
M.inject_results     = inject_results

-- Inject tool results from stream-accumulated tool calls into messages.
-- tool_calls: array of { id, name, input_parts } from handle_compat_streaming
-- results: array of result strings
function M.inject_results_from_stream(ctx, tool_calls, results)
    local rb = ctx.request_body
    rb.messages = rb.messages or {}
    local is_anthropic = (ctx.provider == "anthropic")

    if is_anthropic then
        -- Build assistant content blocks (text + tool_use)
        local assistant_content = {}
        if ctx.stream_accumulated_content and ctx.stream_accumulated_content ~= "" then
            assistant_content[#assistant_content + 1] = {
                type = "text", text = ctx.stream_accumulated_content,
            }
        end
        for _, tc in ipairs(tool_calls) do
            local input = {}
            pcall(function() input = json.decode(table.concat(tc.input_parts)) end)
            assistant_content[#assistant_content + 1] = {
                type  = "tool_use",
                id    = tc.id,
                name  = tc.name,
                input = input,
            }
        end
        local tool_results = {}
        for i, tc in ipairs(tool_calls) do
            tool_results[#tool_results + 1] = {
                type        = "tool_result",
                tool_use_id = tc.id,
                content     = results[i] or "Tool execution failed.",
            }
        end
        rb.messages[#rb.messages + 1] = { role = "assistant", content = assistant_content }
        rb.messages[#rb.messages + 1] = { role = "user",      content = tool_results }
    else
        -- OpenAI format
        local compat_tool_calls = {}
        for i, tc in ipairs(tool_calls) do
            compat_tool_calls[i] = {
                id       = tc.id,
                type     = "function",
                ["function"] = {
                    name      = tc.name,
                    arguments = table.concat(tc.input_parts),
                },
            }
        end
        rb.messages[#rb.messages + 1] = {
            role       = "assistant",
            content    = ctx.stream_accumulated_content or nil,
            tool_calls = compat_tool_calls,
        }
        for i, tc in ipairs(tool_calls) do
            rb.messages[#rb.messages + 1] = {
                role         = "tool",
                tool_call_id = tc.id,
                content      = results[i] or "Tool execution failed.",
            }
        end
    end

    ctx.raw_request_body = json.encode(rb)
end

-- (emit_sse_status and handle_direct_answer removed — tool execution and
-- SSE emission now happen inside upstream.lua's streaming loop)

-- ── Main ─────────────────────────────────────────────────────────────────────

function M.run(ctx)
    local provider = ctx.provider
    if not provider then return end

    local is_anthropic = (provider == "anthropic")
    if not is_anthropic and not SUPPORTED_PROVIDERS[provider] then return end

    -- ── 1. Determine available tools ─────────────────────────────────────────
    local tool_names = {}
    local headers = ngx.req.get_headers()

    -- Project tools (read_file, write_file) — always available when project context exists
    local project_id = headers["x-project-id"]
    if project_id and project_id ~= "" then
        ctx.project_id = project_id
        tool_names[#tool_names + 1] = "read_file"
        tool_names[#tool_names + 1] = "write_file"
    end

    -- fetch_url: check if last user message has a URL
    local msgs = ctx.request_body and ctx.request_body.messages or {}
    local has_url = false
    for i = #msgs, 1, -1 do
        local m = msgs[i]
        if m.role == "user" then
            local text = type(m.content) == "string" and m.content or ""
            if type(m.content) == "table" then
                for _, block in ipairs(m.content) do
                    if type(block) == "table" and block.text then text = text .. " " .. block.text end
                end
            end
            -- Skip injected context
            if text:match("^## File:") or text == "Continue" then
                -- keep looking
            else
                has_url = text:match("https?://[%w%.%-]+%.[%w]+") ~= nil
                if has_url then
                    ngx.log(ngx.NOTICE, "tool_loop: URL detected in user msg: ",
                        text:sub(1, 100))
                end
                break
            end
        end
    end
    if has_url then
        tool_names[#tool_names + 1] = "fetch_url"
    end

    -- web_search
    local ws = ctx.gateway_config.web_search
    if type(ws) == "table" and ws.enabled and ws.api_key then
        local activate = (ws.mode == "always")
        if not activate then
            local h = headers["x-aig-web-search"]
            activate = h and h ~= "0" and h ~= "false"
        end
        if activate then
            tool_names[#tool_names + 1] = "web_search"
        end
    end

    -- MCP tools from header
    local mcp_tools = nil
    local mcp_tools_header = headers["x-mcp-tools"]
    if mcp_tools_header and mcp_tools_header ~= "" then
        mcp_tools = json.decode(mcp_tools_header)
        if mcp_tools then
            -- Build name → connector_id map for execution
            ctx.mcp_tools_map = {}
            for _, t in ipairs(mcp_tools) do
                local name = t.name or (t["function"] and t["function"].name)
                local cid  = t.connector_id
                if name and cid then
                    ctx.mcp_tools_map[name] = { connector_id = cid }
                end
            end
        end
    end

    -- ── 2. No tools → skip (normal streaming via upstream) ───────────────────
    if #tool_names == 0 and (not mcp_tools or #mcp_tools == 0) then return end

    ngx.log(ngx.NOTICE, "tool_loop: injecting tools=[", table.concat(tool_names, ","),
        "] mcp=", mcp_tools and #mcp_tools or 0,
        " project=", tostring(project_id),
        " provider=", provider, " model=", ctx.model)

    -- ── 3. Inject tools and set active flag ──────────────────────────────────
    -- The actual tool execution happens in upstream.lua's handle_compat_streaming:
    -- after Leg 1 streams to the client, if tool_use is detected, upstream.lua
    -- calls tool_loop.execute_tool() and starts Leg 2 streaming — all within
    -- the same HTTP response. No buffered round-trip needed.
    inject_tools(ctx, tool_names, mcp_tools)
    ctx.raw_request_body = json.encode(ctx.request_body)
    ctx.tool_loop_active = true  -- signals handle_compat_streaming to intercept tool_use
end

return M
