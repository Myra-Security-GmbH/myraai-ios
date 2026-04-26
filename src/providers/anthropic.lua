-- providers/anthropic.lua — Anthropic Messages API adapter

local json = require("utils.json")

local M = {}

-- ── Claude Code request tracing ───────────────────────────────────────────────
-- Active until 2026-04-24 09:50 UTC (2 hours from deployment).
-- Logs every header and body change for Claude Code requests so we can audit
-- exactly what the gateway modifies vs. what the client sent.
local CC_TRACE_UNTIL = 1777024255

local function cc_trace_active()
    return ngx.time() <= CC_TRACE_UNTIL
end

local function is_claude_code(req_headers)
    local beta = req_headers and req_headers["anthropic-beta"]
    return beta and beta:find("claude%-code%-", 1, false) ~= nil
end

-- Redact credential header values so they don't appear in logs.
local REDACT = { ["x-api-key"] = true, ["authorization"] = true }
local function safe_hval(k, v)
    if REDACT[k:lower()] then
        local s = tostring(v)
        return s:sub(1, 12) .. "…<redacted>"
    end
    return tostring(v)
end

-- Collect cache_control TTLs from a content-block array (recursive for tool_result).
local function collect_ttls(blocks, out)
    if type(blocks) ~= "table" then return end
    for _, blk in ipairs(blocks) do
        if blk.cache_control then
            out[#out+1] = blk.cache_control.ttl or "5m(default)"
        end
        if type(blk.content) == "table" then collect_ttls(blk.content, out) end
    end
end

-- Produce a compact diff string between two body snapshots.
-- Returns a summary string; returns "(none)" when nothing changed.
local function body_diff(orig, final)
    local changes = {}

    -- Top-level keys added or removed
    for k in pairs(final) do
        if orig[k] == nil then
            changes[#changes+1] = "+" .. k
        end
    end
    for k in pairs(orig) do
        if final[k] == nil then
            changes[#changes+1] = "-" .. k
        end
    end

    -- tools: count change + cache_control TTL rewrites
    local ot = orig.tools  or {}
    local ft = final.tools or {}
    if #ot ~= #ft then
        changes[#changes+1] = ("tools.count:%d->%d"):format(#ot, #ft)
    else
        local orig_ttls, final_ttls = {}, {}
        for _, t in ipairs(ot) do
            if t.cache_control then orig_ttls[#orig_ttls+1] = t.cache_control.ttl or "5m(default)" end
        end
        for _, t in ipairs(ft) do
            if t.cache_control then final_ttls[#final_ttls+1] = t.cache_control.ttl or "5m(default)" end
        end
        local os = table.concat(orig_ttls, ",")
        local fs = table.concat(final_ttls, ",")
        if os ~= fs then
            changes[#changes+1] = "tools.cc_ttl:[" .. os .. "]->[" .. fs .. "]"
        end
    end

    -- system: cache_control added or TTL changed
    local function sys_ttls(sys)
        local t = {}
        if type(sys) == "table" then collect_ttls(sys, t) end
        return table.concat(t, ",")
    end
    local os2 = sys_ttls(orig.system)
    local fs2 = sys_ttls(final.system)
    if os2 ~= fs2 then
        changes[#changes+1] = "system.cc_ttl:[" .. os2 .. "]->[" .. fs2 .. "]"
    end

    -- messages: any cache_control mutation
    local function msg_ttls(msgs)
        local t = {}
        for _, m in ipairs(msgs or {}) do
            collect_ttls(type(m.content) == "table" and m.content or {}, t)
        end
        return table.concat(t, ",")
    end
    local om = msg_ttls(orig.messages)
    local fm = msg_ttls(final.messages)
    if om ~= fm then
        changes[#changes+1] = "messages.cc_ttl:[" .. om .. "]->[" .. fm .. "]"
    end

    -- context_management
    if final.context_management and not orig.context_management then
        changes[#changes+1] = "+context_management(" .. (final.context_management.type or "?") .. ")"
    end

    -- stream flag (gateway may normalise this)
    if tostring(orig.stream) ~= tostring(final.stream) then
        changes[#changes+1] = ("stream:%s->%s"):format(tostring(orig.stream), tostring(final.stream))
    end

    return #changes > 0 and table.concat(changes, " | ") or "(none)"
end

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
    elseif ttl == "5m" then
        return { type = "ephemeral" }
    end
    return { type = "ephemeral" }   -- nil/unset → no ttl field, Anthropic defaults to 5m
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

-- Overwrite all existing cache_control blocks in system and messages to use
-- the gateway-configured TTL. Required when the client (e.g. Claude Code)
-- already manages its own prompt caching: mixing ttl='5m' from the client
-- with ttl='1h' injected later causes an Anthropic 400 (longer TTLs must
-- precede shorter ones in tools→system→messages processing order).
-- Recursively overwrite cache_control in a content-block array.
-- Claude Code nests cache_control inside tool_result blocks:
--   msg.content[i].type == "tool_result"
--     .content[j].cache_control  ← second level, previously missed
local function overwrite_blocks(blocks, cc)
    if type(blocks) ~= "table" then return end
    for _, blk in ipairs(blocks) do
        if blk.cache_control then blk.cache_control = cc end
        -- Recurse into tool_result nested content arrays
        if type(blk.content) == "table" then
            overwrite_blocks(blk.content, cc)
        end
    end
end

local function overwrite_cache_ttl(body, ttl)
    if not ttl then return end  -- nil = pass client TTL through unchanged
    local cc = cache_control_block(ttl)
    -- Tools must be overwritten first: Claude Code places cache_control on tool
    -- schemas with 5m TTL. Leaving them at 5m while system/messages get 1h
    -- creates an invalid ordering (shorter before longer) that causes Anthropic
    -- to silently drop all caching.
    for _, tool in ipairs(body.tools or {}) do
        if tool.cache_control then tool.cache_control = cc end
    end
    overwrite_blocks(body.system, cc)
    for _, msg in ipairs(body.messages or {}) do
        overwrite_blocks(msg.content, cc)
    end
end

-- Return true when the client has cache_control on any tool schema.
-- Older Claude Code versions (pre prompt-caching-scope-2026-01-05) placed
-- cache_control on tools; newer versions place it on system/messages instead.
-- Used as a secondary guard; is_claude_code() is the primary guard for CC.
local function client_manages_tool_cache(tools)
    if type(tools) ~= "table" then return false end
    for _, t in ipairs(tools) do
        if type(t) == "table" and t.cache_control then return true end
    end
    return false
end

-- Return true when the request should be treated as a Claude Code client.
-- These clients manage their own caching and should not have tools injected.
local function skip_tool_injection(req_headers, tools)
    return is_claude_code(req_headers) or client_manages_tool_cache(tools)
end

-- ── Context compaction helpers ────────────────────────────────────────────────
--
-- Estimates input token count from message content (chars ÷ 3.5).
-- Used to decide whether to trigger Anthropic's native compaction API.
-- Intentionally approximate — accuracy within ±15% is sufficient for threshold gating.
local function estimate_tokens(system, messages)
    local chars = 0
    -- System prompt
    if type(system) == "string" then
        chars = chars + #system
    elseif type(system) == "table" then
        for _, blk in ipairs(system) do
            if type(blk.text) == "string" then chars = chars + #blk.text end
        end
    end
    -- Messages
    for _, msg in ipairs(messages or {}) do
        if type(msg.content) == "string" then
            chars = chars + #msg.content
        elseif type(msg.content) == "table" then
            for _, blk in ipairs(msg.content) do
                if type(blk) == "table" then
                    if type(blk.text) == "string" then chars = chars + #blk.text end
                    -- Recurse into tool_result nested content
                    if type(blk.content) == "table" then
                        for _, inner in ipairs(blk.content) do
                            if type(inner.text) == "string" then chars = chars + #inner.text end
                        end
                    end
                end
            end
        end
    end
    return math.floor(chars / 3.5)
end

-- Anthropic's compaction API requires a minimum context size to work.
-- Attempting compaction below this causes a 400 error from the API.
local ANTHROPIC_MIN_COMPACT_TOKENS = 50000

-- Public alias so other modules (upstream.lua) can estimate token counts
-- without duplicating the character-counting logic.
function M.estimate_tokens_public(system, messages)
    return estimate_tokens(system, messages)
end

-- Inject Anthropic's native compaction when context exceeds the gateway threshold.
-- Sets ctx.compact_requested so build_headers can add the required beta header.
local function maybe_inject_compaction(body, ctx)
    local cc = ctx.gateway_config and ctx.gateway_config.context_compaction
    -- cc may be cjson.null (userdata) when the gateway DB field is JSON null
    if type(cc) ~= "table" or not cc.enabled then return end
    local threshold = cc.threshold_tokens or 200000
    local estimated = estimate_tokens(body.system, body.messages)
    -- Guard: only trigger if above both our threshold AND Anthropic's API minimum.
    if estimated < threshold or estimated < ANTHROPIC_MIN_COMPACT_TOKENS then return end
    body.context_management = { type = "compact_20260112" }
    ctx.compact_requested        = true
    ctx.compaction_tokens_before = estimated  -- saved for savings calculation in log phase
    ngx.log(ngx.NOTICE,
        "[compaction] triggering: estimated_tokens=", estimated,
        " threshold=", threshold,
        " gateway=", tostring(ctx.gateway_id),
        " model=", tostring(ctx.model))
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
    -- Anthropic native web search beta — only when the gateway will inject the tool.
    -- Skipped for Claude Code (is_claude_code) and for any client with cache_control
    -- on tools (client_manages_tool_cache). Newer CC versions use prompt-caching-scope
    -- and place cache_control on system/messages, not tools, so the tool check alone
    -- is insufficient — the CC identity check is the primary guard.
    local rb = ctx.request_body
    if not skip_tool_injection(req_headers, rb and rb.tools) then
        local ws_beta = "web-search-2025-03-05"
        if headers["anthropic-beta"] then
            headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. ws_beta
        else
            headers["anthropic-beta"] = ws_beta
        end
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
    -- Context compaction: build_request sets ctx.compact_requested when threshold exceeded
    if ctx.compact_requested then
        local compact_beta = "compact-2026-01-12"
        if headers["anthropic-beta"] then
            headers["anthropic-beta"] = headers["anthropic-beta"] .. "," .. compact_beta
        else
            headers["anthropic-beta"] = compact_beta
        end
    end
    -- Forward client identity headers so Anthropic receives the originating app info.
    for _, h in ipairs({ "user-agent", "x-app", "x-claude-code-session-id" }) do
        if req_headers[h] then headers[h] = req_headers[h] end
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

    -- Trace header changes for Claude Code requests.
    if cc_trace_active() and is_claude_code(req_headers) then
        -- Build a lowercase index of outgoing header names for comparison.
        local out_lc = {}
        for k in pairs(headers) do out_lc[k:lower()] = k end

        local dropped, added, changed = {}, {}, {}

        for k, v in pairs(req_headers) do
            local kl = k:lower()
            if out_lc[kl] then
                -- Header present in both — check if value changed.
                local oval = safe_hval(k, v)
                local nval = safe_hval(k, headers[out_lc[kl]])
                if oval ~= nval then
                    changed[#changed+1] = k .. ": [" .. oval .. "]=>[" .. nval .. "]"
                end
            else
                dropped[#dropped+1] = k .. "=" .. safe_hval(k, v)
            end
        end
        for k, v in pairs(headers) do
            if not req_headers[k:lower()] then
                added[#added+1] = k .. "=" .. safe_hval(k, v)
            end
        end

        ngx.log(ngx.NOTICE,
            "[CC-TRACE][hdr] rid=", ctx.request_id or "-",
            " | DROPPED(", #dropped, ")=[", table.concat(dropped, " , "), "]",
            " | ADDED(", #added, ")=[", table.concat(added, " , "), "]",
            " | CHANGED(", #changed, ")=[", table.concat(changed, " , "), "]")
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
            -- Snapshot original state for trace (before any modifications).
            local orig = (cc_trace_active() and is_claude_code(req_headers))
                         and json.decode(raw) or nil

            body.tools = body.tools or {}
            local already = false
            for _, t in ipairs(body.tools) do
                if t.type == "web_search_20250305" then already = true; break end
            end
            if not already and not skip_tool_injection(req_headers, body.tools) then
                body.tools[#body.tools + 1] = { type = "web_search_20250305", name = "web_search" }
            end
            inject_thinking(body, req_headers)
            strip_deprecated_temperature(body, ctx.model)
            -- Context compaction: inject before prompt caching so token estimate is accurate
            maybe_inject_compaction(body, ctx)
            -- Prompt caching: inject cache_control on native path too
            local pc = ctx.gateway_config and ctx.gateway_config.prompt_caching
            if pc and pc.enabled then
                local ttl = pc.ttl
                -- Normalise any cache_control blocks the client already placed
                -- (e.g. Claude Code always sends ttl='5m') to the gateway TTL so
                -- the request uses a single consistent TTL throughout.
                overwrite_cache_ttl(body, ttl)
                if body.system then
                    body.system = inject_system_cache(body.system, ttl)
                end
                -- NOTE: conversation-history caching (second-to-last user message) was
                -- intentionally removed. The breakpoint moves every turn, so every request
                -- creates a NEW cache entry for the full history that is never read again
                -- (Anthropic cache keys are content-based; a different breakpoint position
                -- is a different key). This generated 2.2B write tokens/month at 1.25-2×
                -- cost with a 0.58× read/write ratio — pure overhead. Only the system
                -- prompt is stable enough to cache profitably.
            end
            local encoded = json.encode(body)
            if not encoded then
                ngx.log(ngx.ERR, "anthropic: json.encode failed, falling back to raw body")
                return json.sanitize_surrogates(raw)
            end
            local result = json.sanitize_surrogates(encoded)

            -- Emit body diff trace for Claude Code.
            if orig then
                -- Also check whether surrogate sanitisation actually changed anything.
                local surrogates_changed = result ~= json.sanitize_surrogates(encoded)
                local diff = body_diff(orig, body)
                -- Count total cache_control blocks in original messages (summary context).
                local orig_msg_cc = 0
                for _, m in ipairs(orig.messages or {}) do
                    if type(m.content) == "table" then
                        local t = {}; collect_ttls(m.content, t)
                        orig_msg_cc = orig_msg_cc + #t
                    end
                end
                ngx.log(ngx.NOTICE,
                    "[CC-TRACE][body] rid=", ctx.request_id or "-",
                    " model=", ctx.model or "-",
                    " turns=", #(orig.messages or {}),
                    " orig_msg_cc_blocks=", orig_msg_cc,
                    " orig_tools=", #(orig.tools or {}),
                    " surrogates_changed=", tostring(surrogates_changed),
                    " body_diff=[", diff, "]")
            end

            return result
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

    -- Prompt caching: only cache the system prompt (stable across turns).
    -- Conversation-history caching (second-to-last user message) was removed:
    -- the breakpoint moves every turn → different cache key every turn → every
    -- request creates a new write that is never read, paying 1.25-2× for nothing.
    local pc = ctx.gateway_config and ctx.gateway_config.prompt_caching
    if pc and pc.enabled then
        local ttl = pc.ttl
        if body.system then
            body.system = inject_system_cache(body.system, ttl)
        end
        ngx.log(ngx.DEBUG, "prompt_caching: injected system cache_control ttl=", ttl,
            " system=", body.system ~= nil and "yes" or "no")
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

    -- Anthropic native web search — injected unless the client manages its own
    -- tool-level caching (cache_control on tools). Changing the tools array in
    -- that case invalidates the client's tool cache key → costly re-write.
    if not body.tools then body.tools = {} end
    local already = false
    for _, t in ipairs(body.tools) do
        if t.type == "web_search_20250305" then already = true; break end
    end
    if not already and not skip_tool_injection(req_headers, body.tools) then
        body.tools[#body.tools + 1] = { type = "web_search_20250305", name = "web_search" }
    end

    -- Extended thinking — inject after all other body fields are set
    inject_thinking(body, req_headers)
    strip_deprecated_temperature(body, ctx.model)
    -- Context compaction
    maybe_inject_compaction(body, ctx)

    local encoded = json.encode(body)
    if not encoded then
        ngx.log(ngx.ERR, "anthropic: json.encode failed for compat request body")
        return nil
    end
    return json.sanitize_surrogates(encoded)
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
    local cc    = usage.cache_creation or {}
    return {
        content                  = content,
        input_tokens             = usage.input_tokens          or 0,
        output_tokens            = usage.output_tokens         or 0,
        cache_creation_tokens    = cc.ephemeral_5m_input_tokens or usage.cache_creation_input_tokens or 0,
        cache_creation_1h_tokens = cc.ephemeral_1h_input_tokens or 0,
        cache_read_tokens        = usage.cache_read_input_tokens     or 0,
        cache_deletion_tokens    = usage.cache_deletion_input_tokens or 0,
        raw                      = body,
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

    -- Detect compaction block: Anthropic inserts a content_block_start with
    -- type="compaction" and a summary field when context compaction fires.
    local compaction_summary
    if chunk.type == "content_block_start"
       and chunk.content_block
       and chunk.content_block.type == "compaction" then
        compaction_summary = chunk.content_block.summary or ""
        ngx.log(ngx.NOTICE, "[compaction] summary block received, length=", #compaction_summary)
    end

    -- Capture tool input_json_delta so callers can reconstruct tool arguments
    if chunk.type == "content_block_delta"
       and chunk.delta
       and chunk.delta.type == "input_json_delta" then
        tool_input_delta = chunk.delta.partial_json
    end

    local done = (chunk.type == "message_stop")

    local stop_reason
    local input_tokens, output_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, cache_deletion_tokens
    if chunk.type == "message_delta" then
        if chunk.delta then stop_reason = chunk.delta.stop_reason end
        if chunk.usage then output_tokens = chunk.usage.output_tokens end
    end
    if chunk.type == "message_start" and chunk.message and chunk.message.usage then
        local u  = chunk.message.usage
        local cc = u.cache_creation or {}
        input_tokens             = u.input_tokens
        cache_creation_tokens    = cc.ephemeral_5m_input_tokens or u.cache_creation_input_tokens
        cache_creation_1h_tokens = cc.ephemeral_1h_input_tokens
        cache_read_tokens        = u.cache_read_input_tokens
        cache_deletion_tokens    = u.cache_deletion_input_tokens
    end

    return {
        delta                    = delta,
        done                     = done,
        tool_name                = tool_name,
        tool_id                  = tool_id,
        tool_input_delta         = tool_input_delta,
        stop_reason              = stop_reason,
        input_tokens             = input_tokens,
        output_tokens            = output_tokens,
        cache_creation_tokens    = cache_creation_tokens,
        cache_creation_1h_tokens = cache_creation_1h_tokens,
        cache_read_tokens        = cache_read_tokens,
        cache_deletion_tokens    = cache_deletion_tokens,
        compaction_summary       = compaction_summary,
    }
end

return M
