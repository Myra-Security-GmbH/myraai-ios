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

local sqlite3 = require("lsqlite3")
local json    = require("utils.json")
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

-- Migrate: apply schema DDL once from init_by_lua_block (master process).
-- Safe to call multiple times — all statements are CREATE IF NOT EXISTS.
function M.migrate(cfg)
    apply_schema(cfg.sqlite.config_db, "config")
    apply_schema(cfg.sqlite.logs_db,   "logs")
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

-- Fetch all rows.
local function query_all(db, sql, ...)
    local stmt = db:prepare(sql)
    if not stmt then
        return nil, "prepare: " .. db:errmsg()
    end
    stmt:bind_values(...)
    local rows = {}
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
        FROM   gateways g
        JOIN   tenants  t ON t.id = g.tenant_id
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
        SELECT encrypted_key, nonce FROM provider_configs
        WHERE  gateway_id = ? AND provider = ? AND alias = ?
        LIMIT 1
    ]], gateway_id, provider, alias)
    if err then return nil, nil, err end
    if not row then return nil, nil, "not_found" end
    return row.encrypted_key, row.nonce
end

function M.get_auth_token(gateway_id, token_hash)
    return query_one(cfg_db(), [[
        SELECT id, scopes, expires_at FROM auth_tokens
        WHERE  gateway_id = ? AND token_hash = ?
        LIMIT 1
    ]], gateway_id, token_hash)
end

function M.get_routing_rules(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, priority, conditions, actions FROM routing_rules
        WHERE  gateway_id = ? AND enabled = 1
        ORDER  BY priority DESC
    ]], gateway_id)
end

function M.get_model_pricing(provider, model)
    return query_one(cfg_db(), [[
        SELECT input_per_1k, output_per_1k FROM model_pricing
        WHERE  provider = ? AND model = ?
    ]], provider, model)
end

-- ---------------------------------------------------------------------------
-- Write API
-- ---------------------------------------------------------------------------

function M.insert_log(f)
    local err = exec_one(log_db(), [[
        INSERT INTO request_logs
            (id, tenant_id, gateway_id, provider, model, status, cached,
             input_tokens, output_tokens, cost_usd, latency_ms, ts,
             prompt, response, meta)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ]],
        f.id, f.tenant_id, f.gateway_id, f.provider, f.model,
        f.status, f.cached and 1 or 0,
        f.input_tokens, f.output_tokens, f.cost_usd, f.latency_ms, f.ts,
        f.prompt, f.response,
        json.encode(f.meta or {})
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
    local existing = query_one(cfg_db(), "SELECT id FROM tenants WHERE slug = ?", slug)
    if existing then return existing.id end
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO tenants (id, slug, plan, budget_usd) VALUES (?,?,?,?)
    ]], id, slug, plan or "free", budget_usd)
    return id
end

function M.upsert_gateway(tenant_id, slug, config_table)
    local existing = query_one(cfg_db(),
        "SELECT id FROM gateways WHERE tenant_id = ? AND slug = ?", tenant_id, slug)
    if existing then
        exec_one(cfg_db(), "UPDATE gateways SET config = ? WHERE id = ?",
            json.encode(config_table or {}), existing.id)
        return existing.id
    end
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO gateways (id, tenant_id, slug, config) VALUES (?,?,?,?)
    ]], id, tenant_id, slug, json.encode(config_table or {}))
    return id
end

function M.upsert_provider_config(gateway_id, provider, alias, encrypted_key, nonce)
    alias = alias or "default"
    exec_one(cfg_db(), [[
        INSERT INTO provider_configs (id, gateway_id, provider, alias, encrypted_key, nonce)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(gateway_id, provider, alias) DO UPDATE
          SET encrypted_key = excluded.encrypted_key, nonce = excluded.nonce
    ]], uuid(), gateway_id, provider, alias, encrypted_key, nonce)
end

function M.insert_auth_token(gateway_id, token_hash, scopes, expires_at)
    return exec_one(cfg_db(), [[
        INSERT INTO auth_tokens (id, gateway_id, token_hash, scopes, expires_at)
        VALUES (?,?,?,?,?)
    ]], uuid(), gateway_id, token_hash, json.encode(scopes or {}), expires_at)
end

-- ---------------------------------------------------------------------------
-- Monitor / reporting queries (uses already-open handles)
-- ---------------------------------------------------------------------------

function M.get_usage_stats()
    local ldb = log_db()
    local cdb = cfg_db()

    -- Resolve tenant slugs
    local slugs = {}
    local slug_rows = query_all(cdb, "SELECT id, slug FROM tenants") or {}
    for _, r in ipairs(slug_rows) do slugs[r.id] = r.slug end

    local function period(where)
        return query_one(ldb, [[
            SELECT COUNT(*) AS requests,
                   SUM(CASE WHEN cached=1 THEN 1 ELSE 0 END) AS cached,
                   COALESCE(SUM(input_tokens),0)   AS input_tokens,
                   COALESCE(SUM(output_tokens),0)  AS output_tokens,
                   ROUND(COALESCE(SUM(cost_usd),0),6) AS cost_usd,
                   ROUND(COALESCE(AVG(latency_ms),0)) AS avg_latency_ms
            FROM request_logs WHERE ]] .. where) or {}
    end

    local by_tenant = query_all(ldb, [[
        SELECT tenant_id,
               COUNT(*) AS requests,
               COALESCE(SUM(input_tokens),0)  AS input_tokens,
               COALESCE(SUM(output_tokens),0) AS output_tokens,
               ROUND(COALESCE(SUM(cost_usd),0),4) AS cost_usd
        FROM request_logs
        WHERE ts >= strftime('%Y-%m-%dT00:00:00Z','now')
        GROUP BY tenant_id ORDER BY cost_usd DESC
    ]]) or {}

    for _, row in ipairs(by_tenant) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    local recent = query_all(ldb, [[
        SELECT substr(ts,1,19) AS ts, tenant_id, provider, model,
               status, input_tokens, output_tokens,
               ROUND(cost_usd,5) AS cost_usd, latency_ms, cached
        FROM request_logs ORDER BY ts DESC LIMIT 10
    ]]) or {}

    for _, row in ipairs(recent) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    return {
        today    = period("ts >= strftime('%Y-%m-%dT00:00:00Z','now')"),
        hour     = period("ts >= datetime('now','-1 hour')"),
        last_min = period("ts >= datetime('now','-1 minute')"),
        by_tenant = by_tenant,
        recent    = recent,
    }
end

return M
