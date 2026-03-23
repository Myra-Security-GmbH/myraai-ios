-- middleware/transform.lua — parse and normalise the request body
-- Ensures ctx.request_body is an OpenAI-format Lua table.
-- Also resolves provider and model for compat requests.

local json        = require("utils.json")
local compat      = require("providers.compat")
local errors      = require("core.errors")
local req_util    = require("utils.request")
local trace       = require("utils.trace")

local M = {}

-- LiteLLM-style namespace prefixes per provider.
-- These are stripped from the model name before forwarding to the provider API.
-- Order matters for providers with multiple prefixes: longer prefixes first.
local PROVIDER_PREFIXES = {
    gemini     = { "gemini/" },
    vertex     = { "vertex_ai/" },
    azure      = { "azure_ai/", "azure/" },
    groq       = { "groq/" },
    mistral    = { "text-completion-codestral/", "mistral/" },
    together   = { "together_ai/" },
    fireworks  = { "fireworks_ai/" },
    nvidia     = { "nvidia_nim/" },
    sambanova  = { "sambanova/" },
    deepseek   = { "deepseek/" },
    xai        = { "xai/" },
    perplexity = { "perplexity/" },
    cerebras   = { "cerebras/" },
    cohere     = { "cohere/" },
    bedrock    = { "bedrock/" },
    openrouter = { "openrouter/" },
    ollama     = { "ollama/" },
}

-- Strip the provider namespace prefix (if any) from a model ID.
-- Returns the bare model name that the upstream API expects.
local function strip_provider_prefix(model, provider)
    local prefixes = PROVIDER_PREFIXES[provider]
    if not prefixes then return model end
    local lower = model:lower()
    for _, prefix in ipairs(prefixes) do
        if lower:sub(1, #prefix) == prefix then
            return model:sub(#prefix + 1)
        end
    end
    return model
end

function M.run(ctx)
    -- Initialise gateway-level tracing if enabled and not already started.
    -- Playground tokens already set ctx.trace_id in auth.lua.
    if not ctx.trace_id then
        local tracing = ctx.gateway_config and ctx.gateway_config.tracing
        if type(tracing) == "table" and tracing.enabled then
            ctx.trace_id               = ctx.request_id
            ctx.trace_seq              = 0
            ctx.tracing_include_bodies = tracing.include_bodies == true
        end
    end

    -- Body may have already been read by cache_check or DLP
    if not ctx.raw_request_body then
        ctx.raw_request_body = req_util.read_body()
    end

    local raw = ctx.raw_request_body
    if not raw or raw == "" then
        errors.send("INVALID_REQUEST", "Empty request body")
        return
    end

    if not ctx.request_body then
        ctx.request_body = json.decode(raw)
        if not ctx.request_body then
            errors.send("INVALID_REQUEST", "Invalid JSON body")
            return
        end
    end

    local body = ctx.request_body

    -- Resolve model
    ctx.model = body.model
    if not ctx.model then
        errors.send("INVALID_REQUEST", "Missing 'model' field")
        return
    end

    -- Capture pre-normalisation values for tracing
    local original_model    = ctx.model
    local original_provider = ctx.provider

    -- TRACE: request_received — what arrived from the client before any transformation
    if ctx.trace_id then
        local step_data = {
            model          = original_model,
            provider       = original_provider,
            messages_count = body.messages and #body.messages or 0,
            streaming      = body.stream == true,
            size_bytes     = raw and #raw or 0,
            is_compat      = ctx.is_compat,
        }
        if ctx.tracing_include_bodies and body.messages then
            step_data.messages = body.messages
        end
        -- Create the trace record now that we have enough context
        trace.create(ctx, "gateway")
        trace.step(ctx, "request_received", step_data)
    end

    -- For compat endpoint: infer the real provider from the model name.
    -- infer_provider() always returns a provider string (falls back to openrouter).
    if ctx.is_compat then
        ctx.provider      = compat.infer_provider(ctx.model)
        ctx.provider_path = compat.provider_path(ctx.provider_path)
    end

    -- Strip LiteLLM-style provider namespace prefix (e.g. "groq/gemma-7b-it" → "gemma-7b-it").
    -- Must run after ctx.provider is finalised (compat or URL-resolved).
    local bare = strip_provider_prefix(ctx.model, ctx.provider)
    if bare ~= ctx.model then
        ctx.model          = bare
        body.model         = bare
    end

    -- TRACE: request_transformed — what changed after normalisation
    if ctx.trace_id and (ctx.model ~= original_model or ctx.provider ~= original_provider) then
        trace.step(ctx, "request_transformed", {
            model_before    = original_model,
            model_after     = ctx.model,
            provider_before = original_provider,
            provider_after  = ctx.provider,
        })
    end

    -- Collect custom metadata from x-aig-meta-* headers
    local req_headers = ngx.req.get_headers()
    for k, v in pairs(req_headers) do
        local meta_key = k:match("^x%-aig%-meta%-(.+)$")
        if meta_key then
            ctx.meta[meta_key] = v
        end
    end

    -- Honour x-aig-collect-log override
    local collect = req_headers["x-aig-collect-log"]
    if collect == "false" or collect == "0" then
        ctx.skip_log = true
    end
    local collect_payload = req_headers["x-aig-collect-log-payload"]
    if collect_payload == "false" or collect_payload == "0" then
        ctx.skip_log_payload = true
    end
end

return M
