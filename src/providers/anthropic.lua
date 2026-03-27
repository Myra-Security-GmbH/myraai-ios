-- providers/anthropic.lua — Anthropic Messages API adapter

local json = require("utils.json")

local M = {}

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
    -- Anthropic native web search
    if req_headers["x-aig-web-search"] == "1" then
        local ws_beta = "web-search-2025-03-05"
        if headers["anthropic-beta"] then
            headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. ws_beta
        else
            headers["anthropic-beta"] = ws_beta
        end
    end
    -- Forward any x-aig-provider-* overrides as raw provider headers
    for k, v in pairs(req_headers) do
        local fwd = k:match("^x%-aig%-provider%-(.+)$")
        if fwd then headers[fwd] = v end
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
function M.build_request(ctx)
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

    -- Agent Skills (docx, xlsx, pptx, pdf) — add container + code_execution tool
    local skill = ngx.req.get_headers()["x-aig-skill"]
    if skill == "docx" or skill == "xlsx" or skill == "pptx" or skill == "pdf" then
        body.container = { skills = {{ type = "anthropic", skill_id = skill, version = "latest" }} }
        body.tools = {{ type = "code_execution_20250825", name = "code_execution" }}
    end

    -- Anthropic native web search — always injected; Anthropic executes searches
    -- server-side with no external API key required.
    if not body.tools then body.tools = {} end
    local already = false
    for _, t in ipairs(body.tools) do
        if t.type == "web_search_20250305" then already = true; break end
    end
    if not already then
        body.tools[#body.tools + 1] = { type = "web_search_20250305", name = "web_search" }
    end

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
function M.parse_sse_chunk(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end

    local chunk = json.decode(data)
    if not chunk then return nil end

    local delta = ""
    if chunk.type == "content_block_delta" and chunk.delta then
        delta = chunk.delta.text or ""
    end

    local done = (chunk.type == "message_stop")

    local input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens
    if chunk.type == "message_delta" and chunk.usage then
        output_tokens = chunk.usage.output_tokens
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
        input_tokens          = input_tokens,
        output_tokens         = output_tokens,
        cache_creation_tokens = cache_creation_tokens,
        cache_read_tokens     = cache_read_tokens,
    }
end

return M
