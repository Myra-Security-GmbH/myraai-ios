-- providers/ollama.lua — Ollama local model server (OpenAI-compatible wire format)
-- Base URL is read from gateway_config.provider_base_urls.ollama; defaults to localhost.
-- Auth is optional: Ollama does not require a key by default.

local openai = require("providers.openai")
local json   = require("utils.json")

local M = {}

local DEFAULT_BASE = "http://10.232.10.252:11439"

function M.base_url(ctx)
    local base = (ctx.gateway_config
                  and ctx.gateway_config.provider_base_urls
                  and ctx.gateway_config.provider_base_urls.ollama)
                 or DEFAULT_BASE
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

-- Strip "ollama/" namespace prefix before sending to the Ollama API.
-- Models are stored in the catalog as "ollama/<name>" but Ollama itself
-- only recognises the bare name (e.g. "llama3.1", not "ollama/llama3.1").
function M.build_request(ctx)
    local patched = ctx
    if ctx.request_body and ctx.request_body.model then
        local bare = ctx.request_body.model:match("^ollama/(.+)$")
        if bare then
            patched = {}
            for k, v in pairs(ctx) do patched[k] = v end
            patched.request_body = {}
            for k, v in pairs(ctx.request_body) do patched.request_body[k] = v end
            patched.request_body.model = bare
        end
    end
    return openai.build_request(patched)
end

M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
