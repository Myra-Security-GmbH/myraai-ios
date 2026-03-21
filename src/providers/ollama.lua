-- providers/ollama.lua — Ollama local model server (OpenAI-compatible wire format)
-- Base URL priority:
--   1. per-gateway DB config: provider_base_urls.ollama
--   2. system config (config/gateway.lua): provider_base_urls.ollama
--   3. DEFAULT_BASE (standard Ollama localhost port)
-- Auth is optional: Ollama does not require a key by default.

local openai     = require("providers.openai")
local json       = require("utils.json")
local app_config = require("core.app_config")

local M = {}

local DEFAULT_BASE = "http://localhost:11434"

local _sys_base = (app_config.provider_base_urls
                   and app_config.provider_base_urls.ollama)
                  or DEFAULT_BASE

-- System-level default for think mode (nil = not set, false = disabled).
local _sys_think = app_config.ollama and app_config.ollama.think

function M.base_url(ctx)
    local base = (ctx.gateway_config
                  and ctx.gateway_config.provider_base_urls
                  and ctx.gateway_config.provider_base_urls.ollama)
                 or _sys_base
    return base .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Request-Id"] = ctx.request_id or "",
    }
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    return headers
end

-- Resolve effective think setting: per-gateway DB config > system config > nil.
-- Returns false to inject think=false, nil to leave the request unchanged.
local function resolve_think(ctx)
    local gw_ollama = ctx.gateway_config and ctx.gateway_config.ollama
    if gw_ollama ~= nil and type(gw_ollama) == "table" and gw_ollama.think ~= nil then
        return gw_ollama.think
    end
    return _sys_think
end

-- Build the upstream request body.
-- Strips "ollama/" namespace prefix (Ollama only knows bare names).
-- Injects think=false when configured to disable the reasoning channel so the
-- model routes its answer to delta.content instead of delta.reasoning.
function M.build_request(ctx)
    local bare  = ctx.request_body
                  and ctx.request_body.model
                  and ctx.request_body.model:match("^ollama/(.+)$")
    local think = resolve_think(ctx)

    if not bare and think == nil then
        return openai.build_request(ctx)
    end

    local patched = {}
    for k, v in pairs(ctx) do patched[k] = v end
    patched.request_body = {}
    for k, v in pairs(ctx.request_body) do patched.request_body[k] = v end

    if bare  then patched.request_body.model = bare  end
    if think ~= nil then patched.request_body.think = think end

    return openai.build_request(patched)
end

M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
