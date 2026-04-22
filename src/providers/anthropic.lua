-- providers/anthropic.lua — Anthropic Messages API adapter

local json = require("utils.json")

local M = {}

-- ── Prompt caching helpers ────────────────────────────────────────────────────
--
-- Anthropic supports cache_control breakpoints on system prompt and message
-- content blocks. Two TTLs are available:
--   "5m"  (default) — 1.25× base input write cost, free reads at 0.1× base
--   "1h"            — 2.0× base input write cost, free reads at 0.1× base
--
-- Gateway config: gateway_config.prompt_caching = { enabled=true, ttl="1h" }
--
-- Strategy: inject cache_control on
--   1. The system prompt (always; it's the largest stable block)
--   2. The second-to-last user message, if messages >= 4 turns
--      (caches the accumulated conversation history before the current turn)

local function cache_control_block(ttl)
    if ttl == "1h" then
        return { type = "ephemeral", ttl = "1h" }
    end
    return { type = "ephemeral" }   -- default 5-minute TTL
end

-- Wrap a plain string system prompt into a content-block array with cache_control.
-- If already a table (content-block array), append cache_control to the last block.
local function inject_system_cache(system, ttl)
    if type(system) == "string" then
        return {{ type = "text", text = system, cache_control = cache_control_block(ttl) }}
    elseif type(system) == "table" then
        local last = system[#system]
        if last and not last.cache_control then
            last.cache_control = cache_control_block(ttl)
        end
        return system
    end
    return system
end

-- Inject a cache breakpoint on the last content block of a given message.
-- Handles string content (wraps to block array) and block-array content.
local function inject_message_cache(msg, ttl)
    local cc = cache_control_block(ttl)
    if type(msg.content) == "string" then
        msg.content = {{ type = "text", text = msg.content, cache_control = cc }}
    elseif type(msg.content) == "table" and #msg.content > 0 then
        local last = msg.content[#msg.content]
        if last and not last.cache_control then
            last.cache_control = cc
        end
    end
end

local BASE_URL = "https://api.anthropic.com"
local API_VERSION = "2023-06-01"

function M.base_url(ctx)
    -- Anthropic path is always /v1/messages (ignore ctx.provider_path)
    return BASE_URL .. "/v1/messages"
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"]      = "application/json",
        ["x-api-key"]         = api_key,
        ["anthropic-version"] = API_VERSION,
        ["X-Request-Id"]      = ctx.request_id or "",
    }
    local req_headers = ngx.req.get_headers()
    -- Forward anthropic-beta (used by Claude Code for extended thinking etc.)
    if req_headers["anthropic-beta"] then
        headers["anthropic-beta"] = req_headers["anthropic-beta"]
    end
    -- Skills (docx, xlsx, pptx, pdf) require three extra beta headers
    if req_headers["x-aig-skill"] then
        local skill_betas = "code-execution-2025-08-25,skills-2025-10-02,files-api-2025-04-14"
        if headers["anthropic-beta"] then
            headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. skill_betas
        else
            headers["anthropic-beta"] = skill_betas
        end
    end
    -- Anthropic native web search — always enabled; the tool is always injected in
    -- build_request() so the beta header must also always be present.
    local ws_beta = "web-search-2025-03-05"
    if headers["anthropic-beta"] then
        headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. ws_beta
    else
        headers["anthropic-beta"] = ws_beta
    end
    -- Extended thinking: interleaved-thinking beta required when budget > 0
    if req_headers["x-aig-thinking-budget"] then
        local tb_beta = "interleaved-thinking-2025-05-14"
        if headers["anthropic-beta"] then
            headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. tb_beta
        else
            headers["anthropic-beta"] = tb_beta
        end
    end
    -- Forward any x-aig-provider-* overrides as raw provider headers.
    -- Blocked: credentials and headers already controlled by the gateway.
    local BLOCKED = {
        ["x-api-key"]         = true,
        ["anthropic-version"] = true,
        ["content-type"]      = true,
        ["x-request-id"]      = true,
    }
    for k, v in pairs(req_headers) do
        local fwd = k:match("^x%-aig%-provider%-(.+)$")
        if fwd and not BLOCKED[fwd:lower()] then headers[fwd] = v end
    end
    return headers
end

-- Build the Anthropic Messages API request body.
--
-- For native Anthropic endpoints (ctx.is_compat == false) the client already
-- sends Anthropic Messages format, so we pass it through unchanged. This
-- preserves system prompts, tool use/result blocks, extended thinking params,
-- and any other Anthropic-specific fields.
--
-- For the OpenAI-compat endpoint (ctx.is_compat == true) the body arrives in
-- OpenAI chat/completions format and needs converting.
-- Inject extended thinking into a decoded body table (both compat and native paths).
-- Removes temperature (required by Anthropic when thinking is enabled).
local function inject_thinking(body, req_headers)
    local budget_str = req_headers["x-aig-thinking-budget"]
    if not budget_str then return end
    local budget = tonumber(budget_str)
    if not budget or budget <= 0 then return end
    body.thinking = { type = "enabled", budget_tokens = math.floor(budget) }
    -- Anthropic rejects requests with temperature when thinking is active
    body.temperature = nil
end

-- Some Anthropic models (e.g. claude-opus-4-7) deprecate temperature entirely.
-- Strip it to avoid "temperature is deprecated for this model" 400 errors.
local TEMPERATURE_DEPRECATED = {
    ["claude%-opus%-4%-7"]  = true,
    ["claude%-opus%-4%-8"]  = true,
    ["claude%-opus%-4%-9"]  = true,
    ["claude%-opus%-5"]     = true,
}

local function strip_deprecated_temperature(body, model)
    if not body.temperature or not model then return end
    for pat in pairs(TEMPERATURE_DEPRECATED) do
        if model:find(pat) then
            body.temperature = nil
            return
        end
    end
end

function M.build_request(ctx)
    local req_headers = ngx.req.get_headers()
    if not ctx.is_compat then
        -- Native Anthropic path: forward raw body, stripping lone surrogates that
        -- cjson allows but Anthropic's strict UTF-8 parser rejects.
        local raw = ctx.raw_request_body
        local body = json.decode(raw)
        if body then
            body.tools = body.tools or {}
            local already = false
            for _, t in ipairs(body.tools) do
                if t.type == "web_search_20250305" then already = true; break end
            end
            if not already then
                body.tools[#body.tools + 1] = { type = "web_search_20250305", name = "web_search" }
            end
            inject_thinking(body, req_headers)
            strip_deprecated_temperature(body, ctx.model)
            -- Prompt caching: inject cache_control on native path too
            local pc = ctx.gateway_config and ctx.gateway_config.prompt_caching
            if pc and pc.enabled and body.system then
                local ttl = pc.ttl or "5m"
                body.system = inject_system_cache(body.system, ttl)
                -- Cache message history breakpoint (second-to-last user turn)
                local msgs = body.messages or {}
                if #msgs >= 4 then
                    local user_count = 0
                    for i = #msgs, 1, -1 do
                        if msgs[i].role == "user" then
                            user_count = user_count + 1
                            if user_count == 2 then
                                inject_message_cache(msgs[i], ttl)
                                break
                            end
                        end
                    end
                end
            end
            return json.sanitize_surrogates(json.encode(body))
        end
        return json.sanitize_surrogates(raw)
    end

    -- Compat path: convert OpenAI chat/completions → Anthropic Messages
    local src = ctx.request_body

    local system_msg
    local messages = {}
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            system_msg = msg.content
        else
            local content = msg.content
            -- Convert OpenAI-format content arrays to Anthropic native format
            if type(content) == "table" then
                local ant_blocks = {}
                for _, block in ipairs(content) do
                    if block.type == "image_url" and type(block.image_url) == "table" then
                        -- Parse data URL: "data:<mime>;base64,<data>"
                        local url = block.image_url.url or ""
                        local mime, b64 = url:match("^data:([^;]+);base64,(.+)$")
                        if mime and b64 then
                            ant_blocks[#ant_blocks + 1] = {
                                type   = "image",
                                source = { type = "base64", media_type = mime, data = b64 },
                            }
                        end
                    elseif block.type == "document" or block.type == "text" then
                        -- Pass text and document blocks through as-is
                        ant_blocks[#ant_blocks + 1] = block
                    elseif block.type == "tool_use" or block.type == "tool_result" then
                        -- Already Anthropic-format (injected by tool_loop after streaming Leg 1)
                        ant_blocks[#ant_blocks + 1] = block
                    end
                end
                content = ant_blocks
            end
            messages[#messages + 1] = { role = msg.role, content = content }
        end
    end

    local body = {
        model      = ctx.model,
        max_tokens = src.max_tokens or 4096,
        messages   = messages,
    }
    if system_msg        then body.system         = system_msg end

    -- Prompt caching: inject cache_control breakpoints when enabled on this gateway
    local pc = ctx.gateway_config and ctx.gateway_config.prompt_caching
    if pc and pc.enabled then
        local ttl = pc.ttl or "5m"
        -- 1. Cache the system prompt
        if body.system then
            body.system = inject_system_cache(body.system, ttl)
        end
        -- 2. Cache the conversation history: put a breakpoint on the second-to-last
        --    user message so the full prior context is cached before the current turn.
        --    Only when there are enough turns (≥ 4 messages) to make it worthwhile.
        if #messages >= 4 then
            -- Walk backwards to find the second-to-last user message
            local user_count = 0
            for i = #messages, 1, -1 do
                if messages[i].role == "user" then
                    user_count = user_count + 1
                    if user_count == 2 then
                        inject_message_cache(messages[i], ttl)
                        break
                    end
                end
            end
        end
        ngx.log(ngx.DEBUG, "prompt_caching: injected cache_control ttl=", ttl,
            " system=", body.system ~= nil and "yes" or "no",
            " msgs=", #messages)
    end

    if src.temperature   then body.temperature    = src.temperature end
    if src.top_p         then body.top_p          = src.top_p end
    if src.stop          then body.stop_sequences = type(src.stop) == "table"
                                                    and src.stop or {src.stop} end
    if src.stream        then body.stream         = true end

    -- Convert OpenAI-format tools → Anthropic tools
    if src.tools and #src.tools > 0 then
        local ant_tools = {}
        for _, t in ipairs(src.tools) do
            if t.type == "function" and t["function"] then
                ant_tools[#ant_tools + 1] = {
                    name         = t["function"].name,
                    description  = t["function"].description,
                    input_schema = t["function"].parameters
                                   or { type = "object", properties = {} },
                }
            end
        end
        if #ant_tools > 0 then body.tools = ant_tools end
    end

    -- Convert OpenAI tool_choice → Anthropic tool_choice
    if src.tool_choice then
        if type(src.tool_choice) == "string" then
            local map = { none = "none", auto = "auto", required = "any" }
            if map[src.tool_choice] then
                body.tool_choice = { type = map[src.tool_choice] }
            end
        elseif type(src.tool_choice) == "table" and src.tool_choice.type then
            body.tool_choice = { type = src.tool_choice.type }
        end
    end

    -- Agent Skills (docx, xlsx, pptx, pdf) — add container + code_execution tool.
    -- Prepend to existing tools (user-supplied tools already in body.tools) rather
    -- than replacing them, so web_search and any caller tools are preserved.
    local skill = ngx.req.get_headers()["x-aig-skill"]
    if skill == "docx" or skill == "xlsx" or skill == "pptx" or skill == "pdf" then
        body.container = { skills = {{ type = "anthropic", skill_id = skill, version = "latest" }} }
        if not body.tools then body.tools = {} end
        table.insert(body.tools, 1, { type = "code_execution_20250825", name = "code_execution" })
    end

    -- Anthropic native web search — always injected together with its beta header.
    -- The web_search_20250305 tool type requires the matching beta header; both must
    -- be present or absent together.  The beta header is added in build_headers().
    if not body.tools then body.tools = {} end
    local already = false
    for _, t in ipairs(body.tools) do
        if t.type == "web_search_20250305" then already = true; break end
    end
    if not already then
        body.tools[#body.tools + 1] = { type = "web_search_20250305", name = "web_search" }
    end

    -- Extended thinking — inject after all other body fields are set
    inject_thinking(body, req_headers)
    strip_deprecated_temperature(body, ctx.model)

    return json.sanitize_surrogates(json.encode(body))
end

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then return nil, "json decode failed" end
    if body.type == "error" then
        return nil, (body.error and body.error.message) or "provider error"
    end

    local content = ""
    for _, block in ipairs(body.content or {}) do
        if block.type == "text" then
            content = content .. (block.text or "")
        end
        -- thinking, tool_use, tool_result, web_search_result blocks intentionally excluded
    end

    local usage = body.usage or {}
    return {
        content               = content,
        input_tokens          = usage.input_tokens          or 0,
        output_tokens         = usage.output_tokens         or 0,
        cache_creation_tokens = usage.cache_creation_input_tokens or 0,
        cache_read_tokens     = usage.cache_read_input_tokens     or 0,
        raw                   = body,
    }
end

-- Anthropic SSE events: content_block_delta, message_delta (with usage)
--
-- st (stream_state) is an optional table that persists across calls for a
-- single stream (allocated once per stream by upstream.lua).  It tracks:
--   st.thinking_opened — true after <think> is emitted; cleared on </think>.
-- This prevents </think> from leaking when a tool_use block (e.g. web_search)
-- precedes a text block without any preceding thinking block.
function M.parse_sse_chunk(line, st)
    st = st or {}
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end

    local chunk = json.decode(data)
    if not chunk then return nil end

    local delta = ""
    if chunk.type == "content_block_delta" and chunk.delta then
        if chunk.delta.type == "thinking_delta" then
            -- Extended-thinking deltas: streamed as <think>…</think> so the
            -- frontend's existing ThinkingBlock parser picks them up.
            delta = chunk.delta.thinking or ""
        else
            delta = chunk.delta.text or ""
        end
    end

    -- Emit <think> when a thinking content block starts
    if chunk.type == "content_block_start"
       and chunk.content_block
       and chunk.content_block.type == "thinking" then
        delta = "<think>"
        st.thinking_opened = true
    end

    -- Emit </think> only when a thinking block was actually opened this stream.
    -- Guard: st.thinking_opened prevents false positives when a tool_use block
    -- (e.g. web_search) precedes the text block — in that case index > 0 but
    -- no <think> was ever emitted.
    if chunk.type == "content_block_start"
       and chunk.content_block
       and chunk.content_block.type == "text"
       and st.thinking_opened then
        delta = "</think>"
        st.thinking_opened = false
    end

    -- Surface the tool name when a tool-use block starts so the client can
    -- show "Searching the web…" / "Using computer…" etc. in the status bar.
    local tool_name, tool_id, tool_input_delta
    if chunk.type == "content_block_start"
       and chunk.content_block
       and chunk.content_block.type == "tool_use" then
        tool_name = chunk.content_block.name
        tool_id   = chunk.content_block.id
    end

    -- Capture tool input_json_delta so callers can reconstruct tool arguments
    if chunk.type == "content_block_delta"
       and chunk.delta
       and chunk.delta.type == "input_json_delta" then
        tool_input_delta = chunk.delta.partial_json
    end

    local done = (chunk.type == "message_stop")

    local stop_reason
    local input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens
    if chunk.type == "message_delta" then
        if chunk.delta then stop_reason = chunk.delta.stop_reason end
        if chunk.usage then output_tokens = chunk.usage.output_tokens end
    end
    if chunk.type == "message_start" and chunk.message and chunk.message.usage then
        local u = chunk.message.usage
        input_tokens          = u.input_tokens
        cache_creation_tokens = u.cache_creation_input_tokens
        cache_read_tokens     = u.cache_read_input_tokens
    end

    return {
        delta                 = delta,
        done                  = done,
        tool_name             = tool_name,
        tool_id               = tool_id,
        tool_input_delta      = tool_input_delta,
        stop_reason           = stop_reason,   -- "end_turn", "max_tokens", "stop_sequence", …
        input_tokens          = input_tokens,
        output_tokens         = output_tokens,
        cache_creation_tokens = cache_creation_tokens,
        cache_read_tokens     = cache_read_tokens,
    }
end

return M
