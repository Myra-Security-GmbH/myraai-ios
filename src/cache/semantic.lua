-- cache/semantic.lua — vector-similarity response cache
-- Embedding-based cache that catches near-identical prompts differing in minor phrasing.
--
-- Query path (synchronous, content phase):
--   embed incoming prompt → cosine-similarity search across stored embeddings → serve hit
--
-- Store path (asynchronous, log phase via ngx.timer.at):
--   embed response prompt → insert embedding + response into semantic_cache table
--
-- Config (gateway_config.semantic_cache):
--   enabled          boolean  — must be true to activate
--   threshold        number   — cosine similarity cutoff, default 0.95
--   embedding_url    string   — OpenAI-compatible embeddings endpoint
--   embedding_api_key string  — Bearer token for the embedding endpoint
--   embedding_model  string   — model name, e.g. "text-embedding-3-small"
--   max_candidates   number   — max stored embeddings to compare, default 100
--   ttl              number   — seconds before a stored embedding expires, default 86400

local http    = require("resty.http")
local sha256  = require("resty.sha256")
local str_lib = require("resty.string")
local cjson   = require("cjson.safe")
local json    = require("utils.json")
local uuid    = require("utils.uuid")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Concatenate all user/assistant message content into a single string for embedding.
local function extract_prompt_text(ctx)
    local body = ctx.request_body
    if not body then return nil end
    local msgs = body.messages
    if type(msgs) ~= "table" or #msgs == 0 then return nil end
    local parts = {}
    for _, msg in ipairs(msgs) do
        if type(msg.content) == "string" and msg.content ~= "" then
            parts[#parts + 1] = msg.content
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "\n")
end

-- SHA-256 hex of the given string.
local function sha256_hex(s)
    local h = sha256:new()
    h:update(s)
    return str_lib.to_hex(h:final())
end

-- Call an OpenAI-compatible embeddings endpoint synchronously.
-- Returns float array on success, nil + err string on failure.
local function embed_text(text, cfg)
    local httpc = http.new()
    httpc:set_timeout(5000)

    local headers = { ["Content-Type"] = "application/json" }
    if cfg.embedding_api_key and cfg.embedding_api_key ~= "" then
        headers["Authorization"] = "Bearer " .. cfg.embedding_api_key
    end

    local body = json.encode({
        model = cfg.embedding_model or "text-embedding-3-small",
        input = { text },
    })

    local res, err = httpc:request_uri(cfg.embedding_url, {
        method  = "POST",
        body    = body,
        headers = headers,
    })

    if err or not res then
        return nil, "embedding request failed: " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, "embedding endpoint returned " .. tostring(res.status)
    end

    local ok, parsed = pcall(cjson.decode, res.body)
    if not ok or type(parsed) ~= "table" then
        return nil, "embedding response parse error"
    end

    local data = parsed.data
    if type(data) ~= "table" or not data[1] then
        return nil, "embedding response missing data[1]"
    end

    local vec = data[1].embedding
    if type(vec) ~= "table" then
        return nil, "embedding vector not a table"
    end

    return vec
end

-- Cosine similarity between two float arrays of equal length.
-- Returns value in [-1, 1]; returns 0 on zero-magnitude input.
local function cosine_similarity(a, b)
    local dot, mag_a, mag_b = 0, 0, 0
    local n = #a
    for i = 1, n do
        local ai, bi = a[i], b[i]
        dot   = dot   + ai * bi
        mag_a = mag_a + ai * ai
        mag_b = mag_b + bi * bi
    end
    if mag_a == 0 or mag_b == 0 then return 0 end
    return dot / (math.sqrt(mag_a) * math.sqrt(mag_b))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Check if a semantically similar request has a cached response.
-- Returns {response_body, cost_usd, similarity} on hit, nil on miss.
-- Errors are caught and return nil (fail-open).
function M.check(ctx, cfg)
    if not cfg or not cfg.enabled then return nil end
    if not cfg.embedding_url then return nil end

    local text = extract_prompt_text(ctx)
    if not text then return nil end

    local threshold    = cfg.threshold     or 0.95
    local max_cands    = cfg.max_candidates or 100

    -- Compute query embedding synchronously
    local query_vec, err = embed_text(text, cfg)
    if not query_vec then
        ngx.log(ngx.WARN, "semantic cache: embed query failed: ", tostring(err))
        return nil
    end

    -- Fetch candidate embeddings from storage
    local ok, storage = pcall(require, "storage")
    if not ok then return nil end

    local candidates = storage.find_semantic_candidates(
        ctx.gateway_id or "", ctx.model or "", max_cands)
    if not candidates or #candidates == 0 then return nil end

    -- Find best match
    local best_sim, best_row = -1, nil
    for _, row in ipairs(candidates) do
        local ok2, stored_vec = pcall(cjson.decode, row.embedding)
        if ok2 and type(stored_vec) == "table" and #stored_vec == #query_vec then
            local sim = cosine_similarity(query_vec, stored_vec)
            if sim > best_sim then
                best_sim = sim
                best_row = row
            end
        end
    end

    if best_row and best_sim >= threshold then
        -- Async: increment hit counter
        pcall(function() storage.increment_semantic_hit(best_row.id) end)
        return {
            response_body = best_row.response_body,
            cost_usd      = best_row.cost_usd or 0,
            similarity    = best_sim,
        }
    end

    return nil
end

-- Asynchronously compute and store an embedding for the just-served response.
-- Called from cache_store.lua after a successful upstream response.
function M.store_async(ctx, cfg)
    if not cfg or not cfg.enabled then return end
    if not cfg.embedding_url then return end
    if ctx.is_streaming then return end  -- cannot store streaming responses
    if not ctx.response_body then return end

    -- Snapshot the fields we need (ctx is not safe to use inside timer callback)
    local snap = {
        gateway_id    = ctx.gateway_id or "",
        model         = ctx.model or "",
        request_body  = ctx.request_body,
        response_body = ctx.response_body,
        cost_usd      = ctx.cost_usd or 0,
        cfg           = cfg,
    }

    local ok, err = ngx.timer.at(0, function(_, s)
        local text = extract_prompt_text(s)
        if not text then return end

        local vec, verr = embed_text(text, s.cfg)
        if not vec then
            ngx.log(ngx.WARN, "semantic cache: store embed failed: ", tostring(verr))
            return
        end

        local prompt_hash = sha256_hex(text)
        local ttl         = s.cfg.ttl or 86400
        local now         = math.floor(ngx.now())

        local ok2, stor = pcall(require, "storage")
        if not ok2 then return end

        local entry = {
            id            = uuid.v4(),
            gateway_id    = s.gateway_id,
            model         = s.model,
            prompt_hash   = prompt_hash,
            embedding     = cjson.encode(vec),
            response_body = s.response_body,
            cost_usd      = s.cost_usd,
            created_at    = now,
            expires_at    = now + ttl,
        }
        pcall(function() stor.insert_semantic_cache(entry) end)
    end, snap)

    if not ok then
        ngx.log(ngx.WARN, "semantic cache: timer.at failed: ", tostring(err))
    end
end

-- Expose helpers for unit testing
M._cosine_similarity   = cosine_similarity
M._extract_prompt_text = extract_prompt_text
M._embed_text          = embed_text

return M
