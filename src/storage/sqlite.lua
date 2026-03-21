-- storage/sqlite.lua — SQLite backend for persistent storage
-- Uses lsqlite3. Two database files: config.db and logs.db.
--
-- Public interface (mirrors postgres.lua):
--   M.get_gateway(tenant_slug, gateway_slug)  → config table | nil, err
--   M.get_provider_key(gateway_id, provider, alias) → encrypted_key, nonce | nil, err
--   M.get_auth_token(gateway_id, token_hash)  → token row | nil, err
--   M.get_routing_rules(gateway_id)           → list of rule rows
--   M.get_model_pricing(provider, model)      → {input_per_1k, output_per_1k} | nil
--   M.insert_log(fields)                      → nil | err

rawset(_G, "sqlite3", {})  -- lsqlite3 populates this global; pre-declare so write guard doesn't fire
local sqlite3  = require("lsqlite3")
local cjson    = require("cjson.safe")
local json     = require("utils.json")
local uuid_lib = require("utils.uuid")

local M = {}

local _cfg_db  -- handle for config.db (opened once per worker)
local _log_db  -- handle for logs.db

local function schema_path(name)
    -- Resolve relative to this file's directory
    local src = debug.getinfo(1, "S").source:sub(2)  -- strip leading '@'
    return src:match("^(.*/)") .. "schema_" .. name .. ".sql"
end

local function open_db(path)
    local db, err = sqlite3.open(path)
    if not db then
        error("sqlite open " .. path .. ": " .. tostring(err))
    end
    return db
end

local function apply_schema(path, schema_name)
    local db = open_db(path)
    local schema_file = io.open(schema_path(schema_name), "r")
    if schema_file then
        local ddl = schema_file:read("*a")
        schema_file:close()
        local rc = db:exec(ddl)
        if rc ~= sqlite3.OK then
            local msg = db:errmsg()
            db:close()
            error("sqlite schema apply " .. schema_name .. ": " .. msg)
        end
    end
    db:close()
end

-- Add columns that were introduced after initial schema creation (idempotent).
local function migrate_columns(cfg)
    local db = open_db(cfg.sqlite.config_db)
    local cols = {}
    for row in db:nrows("PRAGMA table_info(auth_token)") do cols[row.name] = true end
    if not cols.user_id    then db:exec("ALTER TABLE auth_token ADD COLUMN user_id    TEXT") end
    if not cols.label      then db:exec("ALTER TABLE auth_token ADD COLUMN label      TEXT") end
    if not cols.rate_limit then db:exec("ALTER TABLE auth_token ADD COLUMN rate_limit TEXT") end
    if not cols.budget_usd then db:exec("ALTER TABLE auth_token ADD COLUMN budget_usd REAL") end
    db:close()

    local ldb = open_db(cfg.sqlite.logs_db)
    local lcols = {}
    for row in ldb:nrows("PRAGMA table_info(request_log)") do lcols[row.name] = true end
    if not lcols.user_id          then ldb:exec("ALTER TABLE request_log ADD COLUMN user_id          TEXT") end
    if not lcols.token_label      then ldb:exec("ALTER TABLE request_log ADD COLUMN token_label      TEXT") end
    if not lcols.detectors_fired  then ldb:exec("ALTER TABLE request_log ADD COLUMN detectors_fired  TEXT") end
    if not lcols.scrub_applied    then ldb:exec("ALTER TABLE request_log ADD COLUMN scrub_applied    INTEGER NOT NULL DEFAULT 0") end
    ldb:close()
end

-- Migrate: apply schema DDL once from init_by_lua_block (master process).
-- Safe to call multiple times — all statements are CREATE IF NOT EXISTS.
function M.migrate(cfg)
    apply_schema(cfg.sqlite.config_db, "config")
    apply_schema(cfg.sqlite.logs_db,   "logs")
    migrate_columns(cfg)
end

-- Open DB handles per worker (called from init_worker_by_lua_block).
-- Schema must already be applied via M.migrate().
function M.init(cfg)
    _cfg_db = open_db(cfg.sqlite.config_db)
    _log_db = open_db(cfg.sqlite.logs_db)
end

-- Returns the db handle; opens lazily if not yet initialised.
local function cfg_db()
    if not _cfg_db then
        error("storage/sqlite not initialised — call M.init() first")
    end
    return _cfg_db
end

local function log_db()
    if not _log_db then
        error("storage/sqlite not initialised — call M.init() first")
    end
    return _log_db
end

-- Fetch one row as a Lua table via a prepared statement with ? placeholders.
local function query_one(db, sql, ...)
    local stmt = db:prepare(sql)
    if not stmt then
        return nil, "prepare: " .. db:errmsg()
    end
    stmt:bind_values(...)
    local row
    for r in stmt:nrows() do row = r; break end
    stmt:finalize()
    return row
end

-- Fetch all rows. Always returns a table marked with cjson.array_mt so that
-- an empty result serialises as [] (JSON array) rather than {} (JSON object).
local function query_all(db, sql, ...)
    local stmt = db:prepare(sql)
    if not stmt then
        return nil, "prepare: " .. db:errmsg()
    end
    stmt:bind_values(...)
    local rows = setmetatable({}, cjson.array_mt)
    for r in stmt:nrows() do
        rows[#rows + 1] = r
    end
    stmt:finalize()
    return rows
end

-- Execute a write statement.
local function exec_one(db, sql, ...)
    local stmt = db:prepare(sql)
    if not stmt then
        return "prepare: " .. db:errmsg()
    end
    stmt:bind_values(...)
    local rc = stmt:step()
    stmt:finalize()
    if rc ~= sqlite3.DONE then
        return db:errmsg()
    end
end

-- ---------------------------------------------------------------------------
-- Public read API
-- ---------------------------------------------------------------------------

function M.get_gateway(tenant_slug, gateway_slug)
    local row, err = query_one(cfg_db(), [[
        SELECT t.id AS tenant_id, g.id AS gateway_id, g.config
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  t.slug = ? AND g.slug = ? AND t.deleted_at IS NULL
        LIMIT 1
    ]], tenant_slug, gateway_slug)

    if err then return nil, err end
    if not row then return nil, "not_found" end

    local config = json.decode(row.config or "{}") or {}
    config.tenant_id  = row.tenant_id
    config.gateway_id = row.gateway_id
    return config
end

function M.get_provider_key(gateway_id, provider, alias)
    alias = alias or "default"
    local row, err = query_one(cfg_db(), [[
        SELECT encrypted_key, nonce FROM provider_config
        WHERE  gateway_id = ? AND provider = ? AND alias = ?
        LIMIT 1
    ]], gateway_id, provider, alias)
    if err then return nil, nil, err end
    if not row then return nil, nil, "not_found" end
    return row.encrypted_key, row.nonce
end

function M.get_auth_token(gateway_id, token_hash)
    return query_one(cfg_db(), [[
        SELECT id, scopes, expires_at, user_id, label, rate_limit, budget_usd
        FROM   auth_token
        WHERE  gateway_id = ? AND token_hash = ?
        LIMIT 1
    ]], gateway_id, token_hash)
end

function M.get_routing_rules(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, priority, conditions, actions FROM routing_rule
        WHERE  gateway_id = ? AND enabled = 1
        ORDER  BY priority DESC
    ]], gateway_id)
end

function M.get_model_pricing(provider, model)
    return query_one(cfg_db(), [[
        SELECT input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k
        FROM   model_price
        WHERE  provider = ? AND model = ?
    ]], provider, model)
end

-- ---------------------------------------------------------------------------
-- Write API
-- ---------------------------------------------------------------------------

function M.insert_log(f)
    local err = exec_one(log_db(), [[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status, cached,
             input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
             cost_usd, latency_ms, ts,
             prompt, response, meta, blocked, blocked_by, block_reason,
             guardrail_latency_ms, guardrail_verdict,
             saved_cost_usd, saved_latency_ms,
             upstream_latency_ms, time_to_first_token_ms, upstream_attempts,
             fallback_provider, fallback_model, provider_request_id,
             request_size_bytes, quota_remaining, user_id, token_label,
             detectors_fired, scrub_applied)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ]],
        f.id, f.tenant_id, f.gateway_id, f.provider, f.model,
        f.status, f.cached and 1 or 0,
        f.input_tokens, f.output_tokens,
        f.cache_creation_tokens or 0, f.cache_read_tokens or 0,
        f.cost_usd, f.latency_ms, f.ts,
        f.prompt, f.response,
        json.encode(f.meta or {}),
        f.blocked and 1 or 0,
        f.blocked_by,
        f.block_reason,
        f.guardrail_latency_ms,
        f.guardrail_verdict,
        f.saved_cost_usd,
        f.saved_latency_ms,
        f.upstream_latency_ms,
        f.time_to_first_token_ms,
        f.upstream_attempts or 0,
        f.fallback_provider,
        f.fallback_model,
        f.provider_request_id,
        f.request_size_bytes or 0,
        f.quota_remaining,
        f.user_id,
        f.token_label,
        json.encode(f.detectors_fired or {}),
        f.scrub_applied and 1 or 0
    )
    return err
end

-- ---------------------------------------------------------------------------
-- Admin write helpers (used by admin API and tests)
-- ---------------------------------------------------------------------------

local function uuid()
    return uuid_lib.v4()
end

function M.upsert_tenant(slug, plan, budget_usd)
    local existing = query_one(cfg_db(), "SELECT id FROM tenant WHERE slug = ?", slug)
    if existing then return existing.id end
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO tenant (id, slug, plan, budget_usd) VALUES (?,?,?,?)
    ]], id, slug, plan or "free", budget_usd)
    return id
end

function M.update_tenant(id, plan, budget_usd)
    return exec_one(cfg_db(), [[
        UPDATE tenant SET plan = ?, budget_usd = ? WHERE id = ?
    ]], plan, budget_usd, id)
end

function M.delete_tenant(id)
    return exec_one(cfg_db(), [[
        UPDATE tenant SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?
    ]], id)
end

function M.delete_gateway(id)
    return exec_one(cfg_db(), "DELETE FROM gateway WHERE id = ?", id)
end

function M.upsert_gateway(tenant_id, slug, config_table)
    local existing = query_one(cfg_db(),
        "SELECT id FROM gateway WHERE tenant_id = ? AND slug = ?", tenant_id, slug)
    if existing then
        exec_one(cfg_db(), "UPDATE gateway SET config = ? WHERE id = ?",
            json.encode(config_table or {}), existing.id)
        return existing.id
    end
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO gateway (id, tenant_id, slug, config) VALUES (?,?,?,?)
    ]], id, tenant_id, slug, json.encode(config_table or {}))
    return id
end

function M.upsert_provider_config(gateway_id, provider, alias, encrypted_key, nonce)
    alias = alias or "default"
    exec_one(cfg_db(), [[
        INSERT INTO provider_config (id, gateway_id, provider, alias, encrypted_key, nonce)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(gateway_id, provider, alias) DO UPDATE
          SET encrypted_key = excluded.encrypted_key, nonce = excluded.nonce
    ]], uuid(), gateway_id, provider, alias, encrypted_key, nonce)
end

function M.insert_auth_token(gateway_id, token_hash, scopes, expires_at, user_id, label, rate_limit_json, budget_usd)
    local id = uuid()
    local err = exec_one(cfg_db(), [[
        INSERT INTO auth_token (id, gateway_id, token_hash, scopes, expires_at, user_id, label, rate_limit, budget_usd)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], id, gateway_id, token_hash, json.encode(scopes or {}), expires_at, user_id, label, rate_limit_json, budget_usd)
    if err then return nil, err end
    return id
end

-- ---------------------------------------------------------------------------
-- User write helpers
-- ---------------------------------------------------------------------------

function M.insert_user(tenant_id, email, name, role)
    local id = uuid()
    local err = exec_one(cfg_db(), [[
        INSERT INTO user (id, tenant_id, email, name, role)
        VALUES (?,?,?,?,?)
    ]], id, tenant_id, email, name, role or "member")
    if err then return nil, err end
    return id
end

function M.update_user(id, email, name, role)
    return exec_one(cfg_db(), [[
        UPDATE user SET email = ?, name = ?, role = ? WHERE id = ?
    ]], email, name, role, id)
end

function M.delete_user(id)
    return exec_one(cfg_db(), [[
        UPDATE user SET deleted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?
    ]], id)
end

function M.set_user_gateway_access(user_id, gateway_id)
    return exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO user_gateway_access (user_id, gateway_id) VALUES (?,?)
    ]], user_id, gateway_id)
end

function M.delete_user_gateway_access(user_id, gateway_id)
    return exec_one(cfg_db(), [[
        DELETE FROM user_gateway_access WHERE user_id = ? AND gateway_id = ?
    ]], user_id, gateway_id)
end

-- ---------------------------------------------------------------------------
-- Admin list/read queries
-- ---------------------------------------------------------------------------

function M.list_tenants()
    return query_all(cfg_db(), [[
        SELECT id, slug, plan, budget_usd, created_at FROM tenant
        WHERE deleted_at IS NULL ORDER BY created_at DESC
    ]]) or {}
end

function M.list_gateways(tenant_id)
    return query_all(cfg_db(), [[
        SELECT g.id, g.slug, g.tenant_id, g.config, g.created_at
        FROM gateway g WHERE g.tenant_id = ? ORDER BY g.created_at DESC
    ]], tenant_id) or {}
end

function M.get_gateway_by_id(gateway_id)
    return query_one(cfg_db(), [[
        SELECT g.id, g.slug, g.config, g.created_at, g.tenant_id
        FROM gateway g WHERE g.id = ?
    ]], gateway_id)
end

function M.get_gateway_with_tenant_slug(gateway_id)
    return query_one(cfg_db(), [[
        SELECT g.id, g.slug AS gateway_slug, g.tenant_id,
               t.slug AS tenant_slug
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  g.id = ? AND t.deleted_at IS NULL
    ]], gateway_id)
end

function M.list_auth_tokens(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, token_hash, scopes, expires_at, created_at, user_id, label, rate_limit, budget_usd
        FROM auth_token WHERE gateway_id = ? ORDER BY created_at DESC
    ]], gateway_id) or {}
end

function M.delete_auth_token(token_id)
    return exec_one(cfg_db(), "DELETE FROM auth_token WHERE id = ?", token_id)
end

function M.delete_playground_tokens(gateway_id)
    return exec_one(cfg_db(),
        "DELETE FROM auth_token WHERE gateway_id = ? AND label = 'playground'",
        gateway_id)
end

function M.list_provider_configs(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, provider, alias, created_at FROM provider_config
        WHERE gateway_id = ? ORDER BY provider, alias
    ]], gateway_id) or {}
end

function M.delete_provider_config(gateway_id, provider, alias)
    alias = alias or "default"
    return exec_one(cfg_db(), [[
        DELETE FROM provider_config WHERE gateway_id = ? AND provider = ? AND alias = ?
    ]], gateway_id, provider, alias)
end

function M.list_routing_rules(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, priority, conditions, actions, enabled FROM routing_rule
        WHERE gateway_id = ? ORDER BY priority DESC
    ]], gateway_id) or {}
end

function M.upsert_routing_rule(gateway_id, id, priority, conditions, actions, enabled)
    if id and id ~= "" then
        return exec_one(cfg_db(), [[
            UPDATE routing_rule SET priority=?, conditions=?, actions=?, enabled=?
            WHERE id=? AND gateway_id=?
        ]], priority, json.encode(conditions or {}), json.encode(actions or {}),
            enabled and 1 or 0, id, gateway_id)
    end
    local new_id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO routing_rule (id, gateway_id, priority, conditions, actions, enabled)
        VALUES (?,?,?,?,?,?)
    ]], new_id, gateway_id, priority or 0,
        json.encode(conditions or {}), json.encode(actions or {}),
        enabled ~= false and 1 or 0)
    return new_id
end

function M.delete_routing_rule(rule_id)
    return exec_one(cfg_db(), "DELETE FROM routing_rule WHERE id = ?", rule_id)
end

function M.get_user(id)
    return query_one(cfg_db(), [[
        SELECT id, tenant_id, email, name, role, deleted_at, created_at
        FROM user WHERE id = ?
    ]], id)
end

function M.list_users(tenant_id)
    if tenant_id then
        return query_all(cfg_db(), [[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role, u.created_at,
                   t.slug AS tenant_slug
            FROM user u JOIN tenant t ON t.id = u.tenant_id
            WHERE u.tenant_id = ? AND u.deleted_at IS NULL
            ORDER BY u.created_at DESC
        ]], tenant_id) or {}
    end
    return query_all(cfg_db(), [[
        SELECT u.id, u.tenant_id, u.email, u.name, u.role, u.created_at,
               t.slug AS tenant_slug
        FROM user u JOIN tenant t ON t.id = u.tenant_id
        WHERE u.deleted_at IS NULL
        ORDER BY u.created_at DESC
    ]]) or {}
end

function M.list_user_gateways(user_id)
    return query_all(cfg_db(), [[
        SELECT g.id, g.slug, g.tenant_id
        FROM gateway g
        JOIN user_gateway_access a ON a.gateway_id = g.id
        WHERE a.user_id = ?
        ORDER BY g.slug
    ]], user_id) or {}
end

function M.check_user_gateway_access(user_id, gateway_id)
    local row = query_one(cfg_db(), [[
        SELECT 1 FROM user_gateway_access WHERE user_id = ? AND gateway_id = ?
    ]], user_id, gateway_id)
    return row ~= nil
end

function M.list_user_tokens(user_id)
    return query_all(cfg_db(), [[
        SELECT id, gateway_id, token_hash, scopes, expires_at, created_at, label, rate_limit, budget_usd
        FROM auth_token WHERE user_id = ? ORDER BY created_at DESC
    ]], user_id) or {}
end

function M.list_model_prices()
    return query_all(cfg_db(), [[
        SELECT provider, model, input_per_1k, output_per_1k,
               cache_write_per_1k, cache_read_per_1k, updated_at
        FROM model_price ORDER BY provider, model
    ]]) or {}
end

-- List models with optional provider filter. Returns same shape as list_model_prices.
function M.list_models(provider)
    if provider and provider ~= "" then
        return query_all(cfg_db(), [[
            SELECT provider, model, input_per_1k, output_per_1k,
                   cache_write_per_1k, cache_read_per_1k, updated_at
            FROM   model_price
            WHERE  provider = ?
            ORDER  BY model
        ]], provider) or {}
    end
    return M.list_model_prices()
end

function M.upsert_model_price(provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k)
    return exec_one(cfg_db(), [[
        INSERT INTO model_price (provider, model, input_per_1k, output_per_1k,
                                 cache_write_per_1k, cache_read_per_1k, updated_at)
        VALUES (?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        ON CONFLICT(provider, model) DO UPDATE SET
            input_per_1k       = excluded.input_per_1k,
            output_per_1k      = excluded.output_per_1k,
            cache_write_per_1k = excluded.cache_write_per_1k,
            cache_read_per_1k  = excluded.cache_read_per_1k,
            updated_at         = excluded.updated_at
    ]], provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k)
end

function M.delete_model_price(provider, model)
    return exec_one(cfg_db(), "DELETE FROM model_price WHERE provider=? AND model=?", provider, model)
end

function M.list_logs(filters)
    filters = filters or {}
    local where = {"1=1"}
    local params = {}
    if filters.tenant_id then
        where[#where+1] = "tenant_id = ?"
        params[#params+1] = filters.tenant_id
    end
    if filters.gateway_id then
        where[#where+1] = "gateway_id = ?"
        params[#params+1] = filters.gateway_id
    end
    if filters.provider then
        where[#where+1] = "provider = ?"
        params[#params+1] = filters.provider
    end
    if filters.since then
        where[#where+1] = "ts >= ?"
        params[#params+1] = filters.since
    end
    local limit  = math.min(filters.limit or 50, 200)
    local offset = filters.offset or 0
    local sql = string.format([[
        SELECT id, substr(ts,1,19) AS ts, tenant_id, gateway_id,
               provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes
        FROM request_log WHERE %s ORDER BY ts DESC LIMIT %d OFFSET %d
    ]], table.concat(where, " AND "), limit, offset)
    return query_all(log_db(), sql, table.unpack(params)) or {}
end

-- ---------------------------------------------------------------------------
-- Monitor / reporting queries (uses already-open handles)
-- ---------------------------------------------------------------------------

function M.get_usage_stats()
    local ldb = log_db()
    local cdb = cfg_db()

    -- Resolve tenant slugs
    local slugs = {}
    local slug_rows = query_all(cdb, "SELECT id, slug FROM tenant") or {}
    for _, r in ipairs(slug_rows) do slugs[r.id] = r.slug end

    local function period(where)
        return query_one(ldb, [[
            SELECT COUNT(*) AS requests,
                   SUM(CASE WHEN cached=1  THEN 1 ELSE 0 END) AS cached,
                   SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
                   COALESCE(SUM(input_tokens),0)              AS input_tokens,
                   COALESCE(SUM(output_tokens),0)             AS output_tokens,
                   ROUND(COALESCE(SUM(cost_usd),0),6)         AS cost_usd,
                   ROUND(COALESCE(SUM(saved_cost_usd),0),6)   AS saved_cost_usd,
                   ROUND(COALESCE(AVG(latency_ms),0))         AS avg_latency_ms,
                   ROUND(COALESCE(AVG(upstream_latency_ms),0)) AS avg_upstream_latency_ms
            FROM request_log WHERE ]] .. where) or {}
    end

    local by_tenant = query_all(ldb, [[
        SELECT tenant_id,
               COUNT(*) AS requests,
               COALESCE(SUM(input_tokens),0)  AS input_tokens,
               COALESCE(SUM(output_tokens),0) AS output_tokens,
               ROUND(COALESCE(SUM(cost_usd),0),4) AS cost_usd
        FROM request_log
        WHERE ts >= strftime('%Y-%m-%dT00:00:00Z','now')
        GROUP BY tenant_id ORDER BY cost_usd DESC
    ]]) or {}

    for _, row in ipairs(by_tenant) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    local recent = query_all(ldb, [[
        SELECT substr(ts,1,19) AS ts, tenant_id, provider, model,
               status, input_tokens, output_tokens,
               ROUND(cost_usd,5) AS cost_usd, latency_ms, cached,
               blocked, blocked_by, block_reason,
               guardrail_verdict, guardrail_latency_ms,
               upstream_latency_ms, upstream_attempts,
               fallback_provider, fallback_model,
               ROUND(saved_cost_usd,5) AS saved_cost_usd, request_size_bytes
        FROM request_log ORDER BY ts DESC LIMIT 10
    ]]) or {}

    for _, row in ipairs(recent) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    local recent_blocked = query_all(ldb, [[
        SELECT substr(ts,1,19) AS ts, tenant_id, blocked_by, block_reason, latency_ms
        FROM request_log WHERE blocked = 1
        ORDER BY ts DESC LIMIT 20
    ]]) or {}

    for _, row in ipairs(recent_blocked) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    return {
        today          = period("ts >= strftime('%Y-%m-%dT00:00:00Z','now')"),
        hour           = period("ts >= datetime('now','-1 hour')"),
        last_min       = period("ts >= datetime('now','-1 minute')"),
        by_tenant      = by_tenant,
        recent         = recent,
        recent_blocked = recent_blocked,
    }
end

-- ---------------------------------------------------------------------------
-- Client error log
-- ---------------------------------------------------------------------------

function M.insert_client_error(id, message, stack, url, user_agent, ts)
    return exec_one(log_db(), [[
        INSERT OR IGNORE INTO client_error_log (id, message, stack, url, user_agent, ts)
        VALUES (?,?,?,?,?,?)
    ]], id, message, stack, url, user_agent, ts)
end

function M.list_client_errors(limit)
    return query_all(log_db(), [[
        SELECT id, message, stack, url, user_agent, ts
        FROM   client_error_log
        ORDER  BY ts DESC
        LIMIT  ?
    ]], limit or 200)
end

return M
