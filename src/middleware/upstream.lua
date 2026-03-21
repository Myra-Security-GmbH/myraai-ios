-- middleware/upstream.lua — call the upstream provider with retry + fallback
--
-- Flow:
--   1. Build provider-specific request
--   2. Call provider HTTP endpoint
--   3. On failure or 5xx: retry up to gateway_config.retry_count times,
--      then try each fallback in ctx.fallback_chain
--   4. For streaming (SSE): forward chunks to client, accumulate token counts
--   5. For non-streaming: set ctx.response_body, ctx.provider_status
--   6. On all-providers-failed: return 502

local providers  = require("providers")
local http_util  = require("utils.http")
local errors     = require("core.errors")
local json       = require("utils.json")
local state      = require("state")

local M = {}

-- Attempt a single call to one provider+model. Returns response table or nil, err.
local function call_provider(ctx, provider_name, model, is_streaming)
    local provider_mod, err = providers.get(provider_name)
    if not provider_mod then
        return nil, "provider load: " .. err
    end

    -- Temporarily override ctx provider/model for URL/header building
    local orig_provider = ctx.provider
    local orig_model    = ctx.model
    ctx.provider = provider_name
    ctx.model    = model

    local url     = provider_mod.base_url(ctx)
    -- Allow per-gateway base URL override (used by tests to point at mock provider)
    local overrides = ctx.gateway_config.provider_base_urls
    if overrides and overrides[provider_name] then
        local path = url:match("https?://[^/]+(/.*)") or "/"
        url = overrides[provider_name] .. path
    end
    local headers = provider_mod.build_headers(ctx, ctx.provider_api_key)
    local body    = provider_mod.build_request(ctx)

    ctx.provider = orig_provider
    ctx.model    = orig_model

    local status, resp_headers, body_or_reader, call_err, httpc =
        http_util.request({
            method     = "POST",
            url        = url,
            headers    = headers,
            body       = body,
            timeout_ms = ctx.gateway_config.timeout_ms or 60000,
            stream     = is_streaming,
        })

    if call_err then
        return nil, "http: " .. call_err
    end

    return {
        status        = status,
        headers       = resp_headers,
        body          = body_or_reader,  -- string if non-stream, reader if stream
        httpc         = httpc,
        provider_name = provider_name,
        provider_mod  = provider_mod,
    }
end

-- Stream SSE from provider → client for compat requests.
-- Converts provider-native SSE (Anthropic, Gemini, etc.) to OpenAI
-- chat.completion.chunk format so any OpenAI-compatible client works.
local function handle_compat_streaming(ctx, res)
    ngx.status = 200
    ngx.header["Content-Type"]      = "text/event-stream"
    ngx.header["Cache-Control"]     = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"
    ngx.header["X-AIG-Provider"]    = res.provider_name
    ngx.header["X-AIG-Cache"]       = "MISS"

    local reader       = res.body
    local provider_mod = res.provider_mod
    local buf          = ""
    local chat_id      = "chatcmpl-" .. (ctx.request_id or "aig")
    local model        = ctx.model
    local input_tokens, output_tokens = 0, 0
    local first_chunk_seen = false
    local done_sent        = false

    -- Initial role delta (mirrors OpenAI behaviour)
    local role_line = "data: " .. json.encode({
        id      = chat_id,
        object  = "chat.completion.chunk",
        model   = model,
        choices = {{ index = 0, delta = { role = "assistant", content = "" },
                     finish_reason = json.null }},
    }) .. "\n\n"
    ngx.print(role_line)
    ngx.flush(true)

    while true do
        local chunk, err = reader(8192)
        if err then ngx.log(ngx.ERR, "compat streaming read error: ", err); break end
        if not chunk then break end

        if not first_chunk_seen and chunk ~= "" then
            first_chunk_seen = true
            ctx.time_to_first_token_ms = math.floor(ngx.now() * 1000 - ctx.start_ms)
        end

        buf = buf .. chunk

        local pos = 1
        while true do
            local nl = buf:find("\n", pos, true)
            if not nl then buf = buf:sub(pos); break end
            local line = buf:sub(pos, nl - 1):gsub("\r$", "")
            pos = nl + 1

            local parsed = provider_mod.parse_sse_chunk(line)
            if parsed then
                if parsed.input_tokens          then input_tokens  = parsed.input_tokens          end
                if parsed.output_tokens         then output_tokens = parsed.output_tokens         end
                if parsed.cache_creation_tokens then end  -- tracked internally only
                if parsed.cache_read_tokens     then end

                if parsed.done and not done_sent then
                    local finish_line = "data: " .. json.encode({
                        id      = chat_id,
                        object  = "chat.completion.chunk",
                        model   = model,
                        choices = {{ index = 0, delta = {}, finish_reason = "stop" }},
                    }) .. "\n\ndata: [DONE]\n\n"
                    ngx.print(finish_line)
                    ngx.flush(true)
                    done_sent = true
                elseif parsed.delta and parsed.delta ~= "" then
                    local delta_line = "data: " .. json.encode({
                        id      = chat_id,
                        object  = "chat.completion.chunk",
                        model   = model,
                        choices = {{ index = 0, delta = { content = parsed.delta },
                                     finish_reason = json.null }},
                    }) .. "\n\n"
                    ngx.print(delta_line)
                    ngx.flush(true)
                end
            end
        end
    end

    if not done_sent then
        ngx.print("data: [DONE]\n\n")
        ngx.flush(true)
    end

    if res.httpc then res.httpc:set_keepalive() end

    ctx.input_tokens          = input_tokens
    ctx.output_tokens         = output_tokens
    ctx.cache_creation_tokens = 0
    ctx.cache_read_tokens     = 0
    ctx.is_streaming          = true
    ctx.provider_status       = 200
end

-- Stream SSE from provider to client, accumulating token usage.
local function handle_streaming(ctx, res)
    ngx.status = 200
    ngx.header["Content-Type"]       = "text/event-stream"
    ngx.header["Cache-Control"]      = "no-cache"
    ngx.header["X-Accel-Buffering"]  = "no"
    ngx.header["X-AIG-Provider"]     = res.provider_name
    ngx.header["X-AIG-Cache"]        = "MISS"

    local reader      = res.body
    local provider_mod = res.provider_mod
    local buf         = ""
    local input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens = 0, 0, 0, 0
    local first_chunk_seen = false

    while true do
        local chunk, err = reader(8192)
        if err then
            ngx.log(ngx.ERR, "streaming read error: ", err)
            break
        end
        if not chunk then break end

        if not first_chunk_seen and chunk ~= "" then
            first_chunk_seen = true
            ctx.time_to_first_token_ms = math.floor(ngx.now() * 1000 - ctx.start_ms)
        end

        -- Forward to client immediately
        ngx.print(chunk)
        ngx.flush(true)

        -- Accumulate for token counting
        buf = buf .. chunk

        -- Parse SSE lines from the accumulated buffer
        local pos = 1
        while true do
            local nl = buf:find("\n", pos, true)
            if not nl then
                buf = buf:sub(pos)  -- keep remainder
                break
            end
            local line = buf:sub(pos, nl - 1):gsub("\r$", "")
            pos = nl + 1

            local parsed = provider_mod.parse_sse_chunk(line)
            if parsed then
                if parsed.input_tokens          then input_tokens          = parsed.input_tokens          end
                if parsed.output_tokens         then output_tokens         = parsed.output_tokens         end
                if parsed.cache_creation_tokens then cache_creation_tokens = parsed.cache_creation_tokens end
                if parsed.cache_read_tokens     then cache_read_tokens     = parsed.cache_read_tokens     end
            end
        end
    end

    -- Return connection to pool
    if res.httpc then res.httpc:set_keepalive() end

    ctx.input_tokens          = input_tokens
    ctx.output_tokens         = output_tokens
    ctx.cache_creation_tokens = cache_creation_tokens
    ctx.cache_read_tokens     = cache_read_tokens
    ctx.is_streaming          = true
    ctx.provider_status = 200
end

-- Non-streaming response: buffer full body and parse.
local function handle_buffered(ctx, res)
    local provider_mod = res.provider_mod
    local body_str     = res.body  -- already a string from http_util

    local parsed, err = provider_mod.parse_response(body_str)
    if not parsed then
        return nil, "parse_response: " .. tostring(err)
    end

    -- For compat requests the client speaks OpenAI format, so convert the
    -- provider-native response back to an OpenAI chat.completion envelope.
    if ctx.is_compat then
        body_str = json.encode({
            id      = "chatcmpl-" .. (ctx.request_id or "aig"),
            object  = "chat.completion",
            model   = ctx.model,
            choices = {{
                index         = 0,
                message       = { role = "assistant", content = parsed.content },
                finish_reason = "stop",
            }},
            usage   = {
                prompt_tokens     = parsed.input_tokens,
                completion_tokens = parsed.output_tokens,
                total_tokens      = (parsed.input_tokens or 0) + (parsed.output_tokens or 0),
            },
        })
    end

    ctx.response_body         = body_str
    ctx.input_tokens          = parsed.input_tokens
    ctx.output_tokens         = parsed.output_tokens
    ctx.cache_creation_tokens = parsed.cache_creation_tokens or 0
    ctx.cache_read_tokens     = parsed.cache_read_tokens     or 0
    ctx.provider_status       = res.status
    ctx.is_streaming    = false
    return true
end

function M.run(ctx)
    local is_streaming = ctx.request_body and ctx.request_body.stream == true
    local retry_count  = ctx.gateway_config.retry_count or 2

    -- Build attempt list: primary + fallbacks
    local attempts = {{ provider = ctx.provider, model = ctx.model }}
    for _, fb in ipairs(ctx.fallback_chain or {}) do
        attempts[#attempts + 1] = fb
    end

    local last_err
    local total_attempts = 0

    for attempt_idx, attempt in ipairs(attempts) do
        local provider_name = attempt.provider or ctx.provider
        local model         = attempt.model    or ctx.model

        -- Swap BYOK key if fallback uses a different provider
        if provider_name ~= ctx.provider then
            local byok_vault = require("auth.byok")
            local key, k_err = byok_vault.get_key(ctx.gateway_id, provider_name)
            if not key then
                ngx.log(ngx.WARN, "upstream: no key for fallback provider ",
                        provider_name, ": ", k_err)
                goto continue
            end
            ctx.provider_api_key = key
        end

        local retries = (attempt_idx == 1) and retry_count or 0

        for try = 0, retries do
            if try > 0 then
                ngx.log(ngx.INFO, "upstream retry ", try, "/", retries,
                        " provider=", provider_name)
            end

            total_attempts = total_attempts + 1
            local t_call = ngx.now()
            local res, err = call_provider(ctx, provider_name, model, is_streaming)
            local call_ms = math.floor((ngx.now() - t_call) * 1000)

            if not res then
                last_err = err
                ngx.log(ngx.WARN, "upstream call failed: ", err)
                goto next_try
            end

            -- 5xx from provider → retry
            if res.status >= 500 then
                last_err = "provider HTTP " .. res.status
                ngx.log(ngx.WARN, "upstream: provider returned ", res.status)
                goto next_try
            end

            -- 4xx from provider → pass through immediately (don't retry)
            -- The error body comes from the provider so forward it as-is.
            if res.status >= 400 then
                -- res.body may be a reader function (when client sent stream=true)
                -- even though the provider returned a plain JSON error. Buffer it.
                local body_str = res.body
                if type(body_str) == "function" then
                    local parts = {}
                    while true do
                        local chunk = body_str(8192)
                        if not chunk or chunk == "" then break end
                        parts[#parts + 1] = chunk
                    end
                    body_str = table.concat(parts)
                end
                if res.httpc then res.httpc:set_keepalive() end
                ctx.upstream_latency_ms = call_ms
                ctx.upstream_attempts   = total_attempts
                ctx.provider_request_id = res.headers and
                    (res.headers["x-request-id"] or res.headers["request-id"])
                ctx.provider        = provider_name
                ctx.model           = model
                ctx.response_body   = body_str
                ctx.provider_status = res.status
                ctx.is_streaming    = false
                ngx.status = res.status
                ngx.header["Content-Type"] = "application/json"
                ngx.header["X-AIG-Cache"]  = "MISS"
                ngx.header["X-AIG-Provider"] = provider_name
                ngx.header["X-AIG-Model"]    = model
                return
            end

            -- Success path
            ctx.upstream_latency_ms = call_ms
            ctx.upstream_attempts   = total_attempts
            ctx.provider_request_id = res.headers and
                (res.headers["x-request-id"] or res.headers["request-id"])
            if attempt_idx > 1 then
                ctx.fallback_provider = provider_name
                ctx.fallback_model    = model
            end
            -- Store rolling avg for cache savings estimates
            state.config_set("avg_upstream_ms:" .. provider_name .. ":" .. model,
                tostring(call_ms), 86400)

            -- Update ctx with the actual provider/model used
            ctx.provider = provider_name
            ctx.model    = model
            ngx.header["X-AIG-Provider"] = provider_name
            ngx.header["X-AIG-Model"]    = model

            if is_streaming then
                if ctx.is_compat then
                    handle_compat_streaming(ctx, res)
                else
                    handle_streaming(ctx, res)
                end
                return  -- response already sent; skip rest of pipeline
            else
                local ok, parse_err = handle_buffered(ctx, res)
                if not ok then
                    last_err = parse_err
                    ngx.log(ngx.WARN, "upstream: parse error: ", parse_err)
                    goto next_try
                end

                -- Do NOT ngx.print here; send_response.lua runs after
                -- guardrails_response so it can still block the response.
                ngx.status = res.status
                ngx.header["Content-Type"] = "application/json"
                ngx.header["X-AIG-Cache"]  = "MISS"
                return
            end

            ::next_try::
        end

        ::continue::
    end

    -- All attempts exhausted
    ngx.log(ngx.ERR, "upstream: all providers failed. last_err=", last_err)
    errors.send("ALL_PROVIDERS_FAILED", last_err)
end

return M
