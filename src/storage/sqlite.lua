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

local function open_db(path, busy_ms)
    local db, err = sqlite3.open(path)
    if not db then
        error("sqlite open " .. path .. ": " .. tostring(err))
    end
    if busy_ms then
        db:exec("PRAGMA busy_timeout = " .. busy_ms)
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
    if not lcols.response_raw          then ldb:exec("ALTER TABLE request_log ADD COLUMN response_raw          TEXT") end
    if not lcols.prompt_scrubbed       then ldb:exec("ALTER TABLE request_log ADD COLUMN prompt_scrubbed       TEXT") end
    if not lcols.token_quota_remaining  then ldb:exec("ALTER TABLE request_log ADD COLUMN token_quota_remaining  REAL") end
    if not lcols.tenant_quota_remaining then ldb:exec("ALTER TABLE request_log ADD COLUMN tenant_quota_remaining REAL") end
    ldb:close()

    -- Playground trace tables (added after initial schema)
    local cfg_db2 = open_db(cfg.sqlite.config_db)
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS playground_trace (
            id           TEXT PRIMARY KEY,
            gateway_id   TEXT NOT NULL,
            model        TEXT,
            created_at   INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            completed_at INTEGER,
            status       TEXT NOT NULL DEFAULT 'running',
            error        TEXT
        );
        CREATE TABLE IF NOT EXISTS playground_trace_step (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            trace_id  TEXT NOT NULL REFERENCES playground_trace(id) ON DELETE CASCADE,
            seq       INTEGER NOT NULL,
            step      TEXT NOT NULL,
            data      TEXT NOT NULL DEFAULT '{}',
            ts        INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
        );
        CREATE INDEX IF NOT EXISTS idx_pgt_gateway    ON playground_trace(gateway_id, created_at);
        CREATE INDEX IF NOT EXISTS idx_pgts_trace_seq ON playground_trace_step(trace_id, seq);
    ]])
    cfg_db2:close()
end

-- Detect whether a column is stored as TEXT (old schema) and rebuild the table
-- to use INTEGER timestamps. Safe to call multiple times — no-ops when already INTEGER.
local function migrate_timestamps(cfg)
    -- ---- logs.db ---------------------------------------------------------
    -- Use a generous busy_timeout so concurrent worker connections (during
    -- graceful reload) don't cause the migration to fail silently.
    local ldb = open_db(cfg.sqlite.logs_db, 10000)

    local ts_type = ""
    for row in ldb:nrows("PRAGMA table_info(request_log)") do
        if row.name == "ts" then ts_type = row.type; break end
    end

    if ts_type:upper() ~= "INTEGER" then
        -- Rebuild request_log: convert ISO ts → Unix milliseconds
        local rc = ldb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS request_log_new (
                id             TEXT PRIMARY KEY,
                tenant_id      TEXT NOT NULL,
                gateway_id     TEXT NOT NULL,
                provider       TEXT NOT NULL,
                model          TEXT NOT NULL,
                status         INTEGER NOT NULL,
                cached         INTEGER NOT NULL DEFAULT 0,
                input_tokens          INTEGER NOT NULL DEFAULT 0,
                output_tokens         INTEGER NOT NULL DEFAULT 0,
                cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
                cost_usd       REAL NOT NULL DEFAULT 0,
                latency_ms     INTEGER NOT NULL DEFAULT 0,
                ts             INTEGER NOT NULL,
                prompt         TEXT,
                response       TEXT,
                meta           TEXT NOT NULL DEFAULT '{}',
                blocked        INTEGER NOT NULL DEFAULT 0,
                blocked_by     TEXT,
                block_reason   TEXT,
                guardrail_latency_ms  INTEGER,
                guardrail_verdict     TEXT,
                saved_cost_usd        REAL,
                saved_latency_ms      INTEGER,
                upstream_latency_ms   INTEGER,
                time_to_first_token_ms INTEGER,
                upstream_attempts     INTEGER NOT NULL DEFAULT 0,
                fallback_provider     TEXT,
                fallback_model        TEXT,
                provider_request_id   TEXT,
                request_size_bytes    INTEGER NOT NULL DEFAULT 0,
                quota_remaining       REAL,
                user_id               TEXT,
                token_label           TEXT,
                detectors_fired       TEXT,
                scrub_applied         INTEGER NOT NULL DEFAULT 0,
                response_raw          TEXT,
                prompt_scrubbed       TEXT,
                token_quota_remaining  REAL,
                tenant_quota_remaining REAL
            );
            INSERT INTO request_log_new
                SELECT id, tenant_id, gateway_id, provider, model, status, cached,
                       input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
                       cost_usd, latency_ms,
                       CAST(strftime('%s', ts) AS INTEGER) * 1000,
                       prompt, response, meta, blocked, blocked_by, block_reason,
                       guardrail_latency_ms, guardrail_verdict,
                       saved_cost_usd, saved_latency_ms,
                       upstream_latency_ms, time_to_first_token_ms, upstream_attempts,
                       fallback_provider, fallback_model, provider_request_id,
                       request_size_bytes, quota_remaining, user_id, token_label,
                       detectors_fired, COALESCE(scrub_applied, 0),
                       NULL, NULL, NULL, NULL
                FROM request_log;
            DROP TABLE request_log;
            ALTER TABLE request_log_new RENAME TO request_log;
            CREATE INDEX IF NOT EXISTS idx_log_tenant_ts  ON request_log(tenant_id, ts);
            CREATE INDEX IF NOT EXISTS idx_log_gateway_ts ON request_log(gateway_id, ts);
            CREATE INDEX IF NOT EXISTS idx_log_ts         ON request_log(ts);
            COMMIT;
        ]])
        if rc ~= sqlite3.OK then
            ldb:close()
            error("migrate_timestamps request_log: " .. tostring(rc))
        end

        -- Rebuild client_error_log: convert ISO ts → Unix milliseconds
        ldb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS client_error_log_new (
                id         TEXT PRIMARY KEY,
                message    TEXT NOT NULL,
                stack      TEXT,
                url        TEXT,
                user_agent TEXT,
                ts         INTEGER NOT NULL
            );
            INSERT INTO client_error_log_new
                SELECT id, message, stack, url, user_agent,
                       CAST(strftime('%s', ts) AS INTEGER) * 1000
                FROM client_error_log;
            DROP TABLE client_error_log;
            ALTER TABLE client_error_log_new RENAME TO client_error_log;
            CREATE INDEX IF NOT EXISTS idx_client_error_ts ON client_error_log(ts);
            COMMIT;
        ]])
    end
    ldb:close()

    -- ---- config.db -------------------------------------------------------
    local cdb = open_db(cfg.sqlite.config_db, 10000)

    local ca_type = ""
    for row in cdb:nrows("PRAGMA table_info(tenant)") do
        if row.name == "created_at" then ca_type = row.type; break end
    end

    if ca_type:upper() ~= "INTEGER" then
        -- tenant
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS tenant_new (
                id         TEXT PRIMARY KEY,
                slug       TEXT UNIQUE NOT NULL,
                plan       TEXT NOT NULL DEFAULT 'free',
                budget_usd REAL,
                deleted_at INTEGER,
                created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
            );
            INSERT INTO tenant_new
                SELECT id, slug, plan, budget_usd,
                       CASE WHEN deleted_at IS NOT NULL THEN CAST(strftime('%s', deleted_at) AS INTEGER) END,
                       CAST(strftime('%s', created_at) AS INTEGER)
                FROM tenant;
            DROP TABLE tenant;
            ALTER TABLE tenant_new RENAME TO tenant;
            COMMIT;
        ]])
        -- gateway
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS gateway_new (
                id         TEXT PRIMARY KEY,
                tenant_id  TEXT NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
                slug       TEXT NOT NULL,
                config     TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
                UNIQUE(tenant_id, slug)
            );
            INSERT INTO gateway_new
                SELECT id, tenant_id, slug, config,
                       CAST(strftime('%s', created_at) AS INTEGER)
                FROM gateway;
            DROP TABLE gateway;
            ALTER TABLE gateway_new RENAME TO gateway;
            COMMIT;
        ]])
        -- provider_config
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS provider_config_new (
                id            TEXT PRIMARY KEY,
                gateway_id    TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
                provider      TEXT NOT NULL,
                alias         TEXT NOT NULL DEFAULT 'default',
                encrypted_key TEXT NOT NULL,
                nonce         TEXT NOT NULL,
                created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
                UNIQUE(gateway_id, provider, alias)
            );
            INSERT INTO provider_config_new
                SELECT id, gateway_id, provider, alias, encrypted_key, nonce,
                       CAST(strftime('%s', created_at) AS INTEGER)
                FROM provider_config;
            DROP TABLE provider_config;
            ALTER TABLE provider_config_new RENAME TO provider_config;
            COMMIT;
        ]])
        -- user
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS user_new (
                id         TEXT PRIMARY KEY,
                tenant_id  TEXT NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
                email      TEXT NOT NULL,
                name       TEXT,
                role       TEXT NOT NULL DEFAULT 'member',
                deleted_at INTEGER,
                created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
                UNIQUE(tenant_id, email)
            );
            INSERT INTO user_new
                SELECT id, tenant_id, email, name, role,
                       CASE WHEN deleted_at IS NOT NULL THEN CAST(strftime('%s', deleted_at) AS INTEGER) END,
                       CAST(strftime('%s', created_at) AS INTEGER)
                FROM user;
            DROP TABLE user;
            ALTER TABLE user_new RENAME TO user;
            COMMIT;
        ]])
        -- user_gateway_access (no timestamps, but recreate after user drop)
        cdb:exec([[
            CREATE TABLE IF NOT EXISTS user_gateway_access (
                user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
                gateway_id TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
                PRIMARY KEY (user_id, gateway_id)
            );
        ]])
        -- auth_token
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS auth_token_new (
                id          TEXT PRIMARY KEY,
                gateway_id  TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
                token_hash  TEXT NOT NULL UNIQUE,
                scopes      TEXT NOT NULL DEFAULT '[]',
                expires_at  INTEGER,
                created_at  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
                user_id     TEXT REFERENCES user(id) ON DELETE CASCADE,
                label       TEXT,
                rate_limit  TEXT,
                budget_usd  REAL
            );
            INSERT INTO auth_token_new
                SELECT id, gateway_id, token_hash, scopes,
                       CASE WHEN expires_at IS NOT NULL AND expires_at != ''
                            THEN CAST(strftime('%s', expires_at) AS INTEGER) END,
                       CAST(strftime('%s', created_at) AS INTEGER),
                       user_id, label, rate_limit, budget_usd
                FROM auth_token;
            DROP TABLE auth_token;
            ALTER TABLE auth_token_new RENAME TO auth_token;
            COMMIT;
        ]])
        -- routing_rule (no timestamps to convert)
        -- model_price
        cdb:exec([[
            BEGIN;
            CREATE TABLE IF NOT EXISTS model_price_new (
                provider            TEXT NOT NULL,
                model               TEXT NOT NULL,
                input_per_1k        REAL NOT NULL,
                output_per_1k       REAL NOT NULL,
                cache_write_per_1k  REAL,
                cache_read_per_1k   REAL,
                updated_at          INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
                PRIMARY KEY(provider, model)
            );
            INSERT INTO model_price_new
                SELECT provider, model, input_per_1k, output_per_1k,
                       cache_write_per_1k, cache_read_per_1k,
                       COALESCE(
                           CAST(strftime('%s', updated_at) AS INTEGER),
                           CAST(updated_at AS INTEGER),
                           CAST(strftime('%s','now') AS INTEGER)
                       )
                FROM model_price;
            DROP TABLE model_price;
            ALTER TABLE model_price_new RENAME TO model_price;
            COMMIT;
        ]])
    end
    cdb:close()
end

-- Migrate: apply schema DDL once from init_by_lua_block (master process).
-- Safe to call multiple times — all statements are CREATE IF NOT EXISTS.
function M.migrate(cfg)
    apply_schema(cfg.sqlite.config_db, "config")
    apply_schema(cfg.sqlite.logs_db,   "logs")
    migrate_columns(cfg)
    migrate_timestamps(cfg)
end

-- Open DB handles per worker (called from init_worker_by_lua_block).
-- Schema must already be applied via M.migrate().
function M.init(cfg)
    _cfg_db = open_db(cfg.sqlite.config_db)
    _log_db = open_db(cfg.sqlite.logs_db)
    -- Attach config.db to the log connection so reporting queries can JOIN
    -- cfg.tenant directly in SQL instead of doing a Lua-side slug lookup.
    _log_db:exec("ATTACH DATABASE '" .. cfg.sqlite.config_db:gsub("'", "''") .. "' AS cfg")
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
        SELECT t.id AS tenant_id, g.id AS gateway_id, g.config,
               t.budget_usd AS tenant_budget_usd
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  t.slug = ? AND g.slug = ? AND t.deleted_at IS NULL
        LIMIT 1
    ]], tenant_slug, gateway_slug)

    if err then return nil, err end
    if not row then return nil, "not_found" end

    local config = json.decode(row.config or "{}") or {}
    config.tenant_id         = row.tenant_id
    config.gateway_id        = row.gateway_id
    config.tenant_budget_usd = row.tenant_budget_usd  -- nil when uncapped
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
             detectors_fired, scrub_applied, response_raw, prompt_scrubbed,
             token_quota_remaining, tenant_quota_remaining)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        (f.detectors_fired and #f.detectors_fired > 0) and json.encode(f.detectors_fired) or nil,
        f.scrub_applied and 1 or 0,
        f.response_raw,
        f.prompt_scrubbed,
        f.token_quota_remaining,
        f.tenant_quota_remaining
    )
    return err
end

-- ---------------------------------------------------------------------------
-- Admin write helpers (used by admin API and tests)
-- ---------------------------------------------------------------------------

local function uuid()
    return uuid_lib.v4()
end

-- Fix 5: shared helper — avoids copy-paste across list_logs, get_log,
-- get_usage_stats, list_guardrail_events.
local function decode_detectors(row)
    if row.detectors_fired and row.detectors_fired ~= "" then
        row.detectors_fired = json.decode(row.detectors_fired) or {}
    else
        row.detectors_fired = {}
    end
end

function M.upsert_tenant(slug, plan, budget_usd)
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO tenant (id, slug, plan, budget_usd) VALUES (?,?,?,?)
    ]], id, slug, plan or "free", budget_usd)
    local row = query_one(cfg_db(), "SELECT id FROM tenant WHERE slug = ?", slug)
    return row and row.id
end

function M.update_tenant(id, plan, budget_usd)
    return exec_one(cfg_db(), [[
        UPDATE tenant SET plan = ?, budget_usd = ? WHERE id = ?
    ]], plan, budget_usd, id)
end

function M.delete_tenant(id)
    return exec_one(cfg_db(), [[
        UPDATE tenant SET deleted_at = ? WHERE id = ?
    ]], os.time(), id)
end

function M.delete_gateway(id)
    return exec_one(cfg_db(), "DELETE FROM gateway WHERE id = ?", id)
end

function M.upsert_gateway(tenant_id, slug, config_table)
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT INTO gateway (id, tenant_id, slug, config) VALUES (?,?,?,?)
        ON CONFLICT(tenant_id, slug) DO UPDATE SET config = excluded.config
    ]], id, tenant_id, slug, json.encode(config_table or {}))
    local row = query_one(cfg_db(), [[
        SELECT id FROM gateway WHERE tenant_id = ? AND slug = ?
    ]], tenant_id, slug)
    return row and row.id
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
        UPDATE user SET deleted_at = ? WHERE id = ?
    ]], os.time(), id)
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
        SELECT id, slug, plan, budget_usd,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM tenant WHERE deleted_at IS NULL ORDER BY created_at DESC
    ]]) or {}
end

function M.list_gateways(tenant_id)
    return query_all(cfg_db(), [[
        SELECT g.id, g.slug, g.tenant_id, g.config,
               strftime('%Y-%m-%dT%H:%M:%SZ', g.created_at, 'unixepoch') AS created_at
        FROM gateway g WHERE g.tenant_id = ? ORDER BY g.created_at DESC
    ]], tenant_id) or {}
end

function M.get_gateway_by_id(gateway_id)
    return query_one(cfg_db(), [[
        SELECT g.id, g.slug, g.config, g.tenant_id,
               strftime('%Y-%m-%dT%H:%M:%SZ', g.created_at, 'unixepoch') AS created_at
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
        SELECT id, token_hash, scopes, user_id, label, rate_limit, budget_usd,
               CASE WHEN expires_at IS NOT NULL
                    THEN strftime('%Y-%m-%dT%H:%M:%SZ', expires_at, 'unixepoch') END AS expires_at,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM auth_token WHERE gateway_id = ?
          AND (expires_at IS NULL OR expires_at > ?)
        ORDER BY created_at DESC
    ]], gateway_id, os.time()) or {}
end

function M.delete_auth_token(token_id)
    return exec_one(cfg_db(), "DELETE FROM auth_token WHERE id = ?", token_id)
end

function M.delete_playground_tokens(gateway_id)
    return exec_one(cfg_db(),
        "DELETE FROM auth_token WHERE gateway_id = ? AND label = 'playground'",
        gateway_id)
end

function M.delete_expired_playground_tokens(gateway_id)
    return exec_one(cfg_db(), [[
        DELETE FROM auth_token
        WHERE  gateway_id = ? AND label = 'playground'
          AND  expires_at IS NOT NULL
          AND  expires_at <= ?
    ]], gateway_id, os.time())
end

function M.list_provider_configs(gateway_id)
    return query_all(cfg_db(), [[
        SELECT id, provider, alias,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM provider_config WHERE gateway_id = ? ORDER BY provider, alias
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
        SELECT id, tenant_id, email, name, role,
               CASE WHEN deleted_at IS NOT NULL
                    THEN strftime('%Y-%m-%dT%H:%M:%SZ', deleted_at, 'unixepoch') END AS deleted_at,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM user WHERE id = ?
    ]], id)
end

function M.list_users(tenant_id)
    if tenant_id then
        return query_all(cfg_db(), [[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   strftime('%Y-%m-%dT%H:%M:%SZ', u.created_at, 'unixepoch') AS created_at,
                   t.slug AS tenant_slug
            FROM user u JOIN tenant t ON t.id = u.tenant_id
            WHERE u.tenant_id = ? AND u.deleted_at IS NULL
            ORDER BY u.created_at DESC
        ]], tenant_id) or {}
    end
    return query_all(cfg_db(), [[
        SELECT u.id, u.tenant_id, u.email, u.name, u.role,
               strftime('%Y-%m-%dT%H:%M:%SZ', u.created_at, 'unixepoch') AS created_at,
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
        SELECT id, gateway_id, token_hash, scopes, label, rate_limit, budget_usd,
               CASE WHEN expires_at IS NOT NULL
                    THEN strftime('%Y-%m-%dT%H:%M:%SZ', expires_at, 'unixepoch') END AS expires_at,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM auth_token WHERE user_id = ? ORDER BY created_at DESC
    ]], user_id) or {}
end

function M.list_model_prices()
    return query_all(cfg_db(), [[
        SELECT provider, model, input_per_1k, output_per_1k,
               cache_write_per_1k, cache_read_per_1k,
               strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch') AS updated_at
        FROM model_price ORDER BY provider, model
    ]]) or {}
end

-- List models with optional provider filter. Returns same shape as list_model_prices.
function M.list_models(provider)
    if provider and provider ~= "" then
        return query_all(cfg_db(), [[
            SELECT provider, model, input_per_1k, output_per_1k,
                   cache_write_per_1k, cache_read_per_1k,
                   strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch') AS updated_at
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
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(provider, model) DO UPDATE SET
            input_per_1k       = excluded.input_per_1k,
            output_per_1k      = excluded.output_per_1k,
            cache_write_per_1k = excluded.cache_write_per_1k,
            cache_read_per_1k  = excluded.cache_read_per_1k,
            updated_at         = excluded.updated_at
    ]], provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, os.time())
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
    if filters.model then
        where[#where+1] = "model = ?"
        params[#params+1] = filters.model
    end
    if filters.status then
        where[#where+1] = "status = ?"
        params[#params+1] = tonumber(filters.status)
    end
    if filters.blocked == "1" or filters.blocked == true then
        where[#where+1] = "blocked = 1"
    end
    if filters.since then
        where[#where+1] = "ts >= ?"
        params[#params+1] = filters.since
    end
    -- guardrail_outcome filter: "blocked" | "scrubbed" | "flagged" | "any"
    if filters.guardrail_outcome then
        local o = filters.guardrail_outcome
        if o == "blocked" then
            where[#where+1] = "blocked = 1"
        elseif o == "scrubbed" then
            where[#where+1] = "scrub_applied = 1 AND blocked = 0"
        elseif o == "flagged" then
            where[#where+1] = "detectors_fired IS NOT NULL AND detectors_fired != '[]' AND blocked = 0 AND scrub_applied = 0"
        elseif o == "any" then
            where[#where+1] = "(blocked = 1 OR scrub_applied = 1 OR (detectors_fired IS NOT NULL AND detectors_fired != '[]'))"
        end
    end
    local limit  = math.min(filters.limit or 50, 200)
    local offset = filters.offset or 0
    local sql = string.format([[
        SELECT id,
               strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', ts/1000, 'unixepoch') AS ts,
               tenant_id, gateway_id,
               provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes,
               detectors_fired, scrub_applied, response_raw
        FROM request_log WHERE %s ORDER BY ts DESC LIMIT %d OFFSET %d
    ]], table.concat(where, " AND "), limit, offset)
    local rows = query_all(log_db(), sql, table.unpack(params)) or {}
    for _, row in ipairs(rows) do decode_detectors(row) end
    return rows
end

function M.get_log(id)
    local row = query_one(log_db(), [[
        SELECT id,
               strftime('%Y-%m-%dT%H:%M:%SZ', ts/1000, 'unixepoch') AS ts,
               tenant_id, gateway_id, provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes,
               detectors_fired, scrub_applied,
               prompt, response, response_raw, prompt_scrubbed
        FROM request_log WHERE id = ?
    ]], id)
    if not row then return nil end
    decode_detectors(row)
    return row
end

-- ---------------------------------------------------------------------------
-- Monitor / reporting queries (uses already-open handles)
-- ---------------------------------------------------------------------------

function M.get_usage_stats()
    local ldb = log_db()

    -- Period thresholds in milliseconds
    local now          = math.floor(ngx.now())
    local today_ms     = (now - (now % 86400)) * 1000
    local yesterday_ms = today_ms - 86400 * 1000
    local last_7d_ms   = today_ms - 7 * 86400 * 1000
    local hour_ms      = (now - 3600) * 1000
    local last_min_ms  = (now - 60) * 1000

    -- Build one SELECT with conditional aggregates for all 5 periods.
    -- Values embedded as literals (all are integer results of Lua arithmetic).
    -- WHERE ts >= last_7d_ms covers every period; inner CASE WHENs slice each one.
    local function pcols(p, cond)
        return string.format([[
            COUNT(CASE WHEN %s THEN 1 END) AS %s_req,
            SUM(CASE WHEN %s AND cached=1 THEN 1 ELSE 0 END) AS %s_cached,
            SUM(CASE WHEN %s AND blocked=1 THEN 1 ELSE 0 END) AS %s_blocked,
            SUM(CASE WHEN %s AND scrub_applied=1 AND blocked=0 THEN 1 ELSE 0 END) AS %s_scrubbed,
            SUM(CASE WHEN %s AND blocked=0 AND scrub_applied=0 AND detectors_fired IS NOT NULL AND detectors_fired != '[]' THEN 1 ELSE 0 END) AS %s_flagged,
            COALESCE(SUM(CASE WHEN %s THEN input_tokens END),0) AS %s_in_tok,
            COALESCE(SUM(CASE WHEN %s THEN output_tokens END),0) AS %s_out_tok,
            ROUND(COALESCE(SUM(CASE WHEN %s THEN cost_usd END),0),6) AS %s_cost,
            ROUND(COALESCE(SUM(CASE WHEN %s THEN saved_cost_usd END),0),6) AS %s_saved,
            ROUND(COALESCE(AVG(CASE WHEN %s THEN latency_ms END),0)) AS %s_avg_lat,
            ROUND(COALESCE(AVG(CASE WHEN %s THEN upstream_latency_ms END),0)) AS %s_avg_up]],
            cond,p, cond,p, cond,p, cond,p, cond,p,
            cond,p, cond,p, cond,p, cond,p, cond,p, cond,p)
    end

    local all_sql = string.format("SELECT %s, %s, %s, %s, %s FROM request_log WHERE ts >= %d",
        pcols("lm", "ts >= " .. last_min_ms),
        pcols("hr", "ts >= " .. hour_ms),
        pcols("td", "ts >= " .. today_ms),
        pcols("yd", "ts >= " .. yesterday_ms .. " AND ts < " .. today_ms),
        pcols("l7", "1=1"),
        last_7d_ms)

    local r = query_one(ldb, all_sql) or {}

    local function extract(p)
        return {
            requests              = r[p.."_req"]     or 0,
            cached                = r[p.."_cached"]  or 0,
            blocked               = r[p.."_blocked"] or 0,
            scrubbed              = r[p.."_scrubbed"] or 0,
            flagged               = r[p.."_flagged"] or 0,
            input_tokens          = r[p.."_in_tok"]  or 0,
            output_tokens         = r[p.."_out_tok"] or 0,
            cost_usd              = r[p.."_cost"]    or 0,
            saved_cost_usd        = r[p.."_saved"]   or 0,
            avg_latency_ms        = r[p.."_avg_lat"] or 0,
            avg_upstream_latency_ms = r[p.."_avg_up"] or 0,
        }
    end

    -- by_tenant: JOIN cfg.tenant (ATTACHed in M.init) for slug resolution in SQL
    local by_tenant = query_all(ldb, [[
        SELECT r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               COUNT(*) AS requests,
               COALESCE(SUM(r.input_tokens),0)  AS input_tokens,
               COALESCE(SUM(r.output_tokens),0) AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4) AS cost_usd
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        WHERE r.ts >= ?
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], today_ms) or {}

    local recent = query_all(ldb, [[
        SELECT strftime('%Y-%m-%dT%H:%M:%SZ', r.ts/1000, 'unixepoch') AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.provider, r.model,
               r.status, r.input_tokens, r.output_tokens,
               ROUND(r.cost_usd,5) AS cost_usd, r.latency_ms, r.cached,
               r.blocked, r.blocked_by, r.block_reason,
               r.guardrail_verdict, r.guardrail_latency_ms,
               r.upstream_latency_ms, r.upstream_attempts,
               r.fallback_provider, r.fallback_model,
               ROUND(r.saved_cost_usd,5) AS saved_cost_usd, r.request_size_bytes
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        ORDER BY r.ts DESC LIMIT 10
    ]]) or {}

    local recent_blocked = query_all(ldb, [[
        SELECT strftime('%Y-%m-%dT%H:%M:%SZ', r.ts/1000, 'unixepoch') AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.blocked_by, r.block_reason, r.latency_ms,
               r.guardrail_latency_ms, r.guardrail_verdict,
               r.blocked, r.scrub_applied, r.detectors_fired,
               r.response_raw, r.prompt_scrubbed
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        WHERE r.blocked = 1
           OR r.scrub_applied = 1
           OR (r.detectors_fired IS NOT NULL AND r.detectors_fired != '[]')
        ORDER BY r.ts DESC LIMIT 20
    ]]) or {}

    for _, row in ipairs(recent_blocked) do decode_detectors(row) end

    return {
        today          = extract("td"),
        yesterday      = extract("yd"),
        last_7d        = extract("l7"),
        hour           = extract("hr"),
        last_min       = extract("lm"),
        by_tenant      = by_tenant,
        recent         = recent,
        recent_blocked = recent_blocked,
    }
end

-- ---------------------------------------------------------------------------
-- Time-series stats
-- ---------------------------------------------------------------------------

-- Returns n buckets of (requests, blocked, cost_usd) aggregated per bucket_sec
-- seconds, ordered oldest → newest, zero-filling any empty buckets.
-- Supported bucket_sec values: 300, 900, 1800, 3600, 21600, 86400.
function M.get_stats_timeseries(bucket_sec, n, end_sec)
    local ldb      = log_db()
    local ref      = end_sec or math.floor(ngx.now())
    local bms      = bucket_sec * 1000   -- bucket size in milliseconds

    -- Align reference time to bucket boundary, compute window start
    local now_bucket_sec = math.floor(ref / bucket_sec) * bucket_sec
    local since_ms       = (now_bucket_sec - (n - 1) * bucket_sec) * 1000

    -- bms is embedded as a literal (not a bind param) to ensure SQLite uses
    -- integer division. Binding it as a Lua number causes real-number division,
    -- making every row its own unique bucket.
    local sql = string.format([[
        SELECT (ts / %d) * %d AS bucket_ts,
               COUNT(*) AS requests,
               SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
               ROUND(COALESCE(SUM(cost_usd),0),6) AS cost_usd
        FROM request_log
        WHERE ts >= ?
        GROUP BY bucket_ts
        ORDER BY bucket_ts ASC
    ]], bms, bms)
    local rows = query_all(ldb, sql, since_ms) or {}

    -- Index results by bucket start ms
    local by_ts = {}
    for _, r in ipairs(rows) do by_ts[r.bucket_ts] = r end

    -- Build complete series with zero-fill for missing buckets
    local result = setmetatable({}, require("cjson").array_mt)
    for i = 0, n - 1 do
        local bts = (now_bucket_sec - (n - 1 - i) * bucket_sec) * 1000
        local r   = by_ts[bts] or {}
        result[#result + 1] = {
            ts       = bts,
            requests = r.requests or 0,
            blocked  = r.blocked  or 0,
            cost_usd = r.cost_usd or 0,
        }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Analytics depth: latency percentiles + top models
-- ---------------------------------------------------------------------------

-- Returns latency percentiles (p50/p95/p99) and top models for the last
-- since_ms epoch milliseconds window (default: last 24 h).
function M.get_analytics_depth(since_ms)
    local ldb    = log_db()
    local cdb    = cfg_db()
    local now_ms = math.floor(ngx.now() * 1000)
    local from   = since_ms or (now_ms - 86400 * 1000)

    -- Percentiles via window function (SQLite ≥ 3.25).
    -- CEIL is required so that small datasets (n=1) still return a value:
    -- without it, rn=1 vs cnt*0.50=0.5 → 1<=0.5 is false → NULL.
    local pct = query_one(ldb, [[
        SELECT
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.50) AS INTEGER) THEN latency_ms END) AS p50,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.95) AS INTEGER) THEN latency_ms END) AS p95,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.99) AS INTEGER) THEN latency_ms END) AS p99
        FROM (
            SELECT latency_ms,
                   ROW_NUMBER() OVER (ORDER BY latency_ms) AS rn,
                   COUNT(*)     OVER ()                    AS cnt
            FROM request_log
            WHERE ts >= ? AND latency_ms IS NOT NULL AND blocked = 0
        )
    ]], from) or {}

    -- Top models by request volume + cost
    local top_models = query_all(ldb, [[
        SELECT model, provider,
               COUNT(*) AS requests,
               ROUND(COALESCE(SUM(cost_usd), 0), 4) AS cost_usd,
               ROUND(COALESCE(AVG(latency_ms), 0))  AS avg_latency_ms
        FROM request_log
        WHERE ts >= ?
        GROUP BY provider, model
        ORDER BY requests DESC
        LIMIT 10
    ]], from) or {}

    -- Usage by tenant
    local slugs = {}
    local slug_rows = query_all(cdb, "SELECT id, slug FROM tenant") or {}
    for _, r in ipairs(slug_rows) do slugs[r.id] = r.slug end

    local by_tenant = query_all(ldb, [[
        SELECT tenant_id,
               COUNT(*) AS requests,
               COALESCE(SUM(input_tokens),0)      AS input_tokens,
               COALESCE(SUM(output_tokens),0)     AS output_tokens,
               ROUND(COALESCE(SUM(cost_usd),0),4) AS cost_usd
        FROM request_log
        WHERE ts >= ?
        GROUP BY tenant_id ORDER BY cost_usd DESC
    ]], from) or {}
    for _, row in ipairs(by_tenant) do
        row.tenant = slugs[row.tenant_id] or row.tenant_id
    end

    return { percentiles = pct, top_models = top_models, by_tenant = by_tenant }
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
        SELECT id, message, stack, url, user_agent,
               strftime('%Y-%m-%dT%H:%M:%SZ', ts/1000, 'unixepoch') AS ts
        FROM   client_error_log
        ORDER  BY ts DESC
        LIMIT  ?
    ]], limit or 200)
end

-- ---------------------------------------------------------------------------
-- Playground trace API
-- ---------------------------------------------------------------------------

function M.create_playground_trace(id, gateway_id, model)
    return exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO playground_trace (id, gateway_id, model)
        VALUES (?, ?, ?)
    ]], id, gateway_id, model)
end

function M.add_playground_trace_step(trace_id, seq, step, data_json)
    return exec_one(cfg_db(), [[
        INSERT INTO playground_trace_step (trace_id, seq, step, data)
        VALUES (?, ?, ?, ?)
    ]], trace_id, seq, step, data_json)
end

function M.complete_playground_trace(id, status, error_msg)
    return exec_one(cfg_db(), [[
        UPDATE playground_trace
        SET status = ?, error = ?, completed_at = ?
        WHERE id = ?
    ]], status, error_msg, os.time(), id)
end

function M.get_playground_trace(id)
    return query_one(cfg_db(), "SELECT * FROM playground_trace WHERE id = ?", id)
end

function M.get_playground_trace_steps(trace_id)
    return query_all(cfg_db(), [[
        SELECT * FROM playground_trace_step WHERE trace_id = ? ORDER BY seq
    ]], trace_id)
end

-- ---------------------------------------------------------------------------
-- Per-gateway guardrail stats (last 24h) and recent events
-- ---------------------------------------------------------------------------

function M.get_gateway_guardrail_stats(gateway_id)
    local ldb  = log_db()
    local since_ms = (math.floor(ngx.now()) - 86400) * 1000
    local stats = query_one(ldb, [[
        SELECT
            SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
            SUM(CASE WHEN scrub_applied=1 AND blocked=0 THEN 1 ELSE 0 END) AS scrubbed,
            SUM(CASE WHEN blocked=0 AND scrub_applied=0
                          AND detectors_fired IS NOT NULL AND detectors_fired != '[]'
                     THEN 1 ELSE 0 END) AS flagged,
            ROUND(COALESCE(AVG(CASE WHEN guardrail_latency_ms IS NOT NULL THEN guardrail_latency_ms END), 0)) AS avg_guardrail_ms
        FROM request_log
        WHERE gateway_id = ? AND ts >= ?
    ]], gateway_id, since_ms) or {}
    return {
        blocked  = stats.blocked  or 0,
        scrubbed = stats.scrubbed or 0,
        flagged  = stats.flagged  or 0,
        avg_guardrail_ms = stats.avg_guardrail_ms or 0,
    }
end

function M.list_guardrail_events(gateway_id, limit)
    limit = math.min(limit or 50, 200)
    local rows = query_all(log_db(), string.format([[
        SELECT strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', ts/1000, 'unixepoch') AS ts,
               blocked, scrub_applied, detectors_fired,
               blocked_by, block_reason,
               guardrail_latency_ms, guardrail_verdict,
               provider, model, latency_ms
        FROM request_log
        WHERE gateway_id = ?
          AND (blocked = 1
               OR scrub_applied = 1
               OR (detectors_fired IS NOT NULL AND detectors_fired != '[]'))
        ORDER BY ts DESC LIMIT %d
    ]], limit), gateway_id) or {}
    for _, row in ipairs(rows) do decode_detectors(row) end
    return rows
end

return M
