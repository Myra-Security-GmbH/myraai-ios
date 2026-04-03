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
    if not cols.user_id       then db:exec("ALTER TABLE auth_token ADD COLUMN user_id       TEXT") end
    if not cols.label         then db:exec("ALTER TABLE auth_token ADD COLUMN label         TEXT") end
    if not cols.rate_limit    then db:exec("ALTER TABLE auth_token ADD COLUMN rate_limit    TEXT") end
    if not cols.budget_usd    then db:exec("ALTER TABLE auth_token ADD COLUMN budget_usd    REAL") end
    if not cols.budget_period then db:exec("ALTER TABLE auth_token ADD COLUMN budget_period TEXT NOT NULL DEFAULT 'monthly'") end

    local tcols = {}
    for row in db:nrows("PRAGMA table_info(tenant)") do tcols[row.name] = true end
    if not tcols.budget_period       then db:exec("ALTER TABLE tenant ADD COLUMN budget_period TEXT NOT NULL DEFAULT 'monthly'") end
    if not tcols.chat_presets_config then db:exec("ALTER TABLE tenant ADD COLUMN chat_presets_config TEXT") end

    local mcols = {}
    for row in db:nrows("PRAGMA table_info(chat_message)") do mcols[row.name] = true end
    if not mcols.gateway_id then db:exec("ALTER TABLE chat_message ADD COLUMN gateway_id TEXT") end

    local ucols = {}
    for row in db:nrows("PRAGMA table_info(user)") do ucols[row.name] = true end
    if not ucols.last_login_at then db:exec("ALTER TABLE user ADD COLUMN last_login_at INTEGER") end

    -- spend_ledger: period-aware persistent spend tracking (replaces shared-dict counters)
    db:exec([[
        CREATE TABLE IF NOT EXISTS spend_ledger (
            entity_type  TEXT    NOT NULL,
            entity_id    TEXT    NOT NULL,
            period       TEXT    NOT NULL,
            amount_micro INTEGER NOT NULL DEFAULT 0,
            updated_at   INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            PRIMARY KEY (entity_type, entity_id, period)
        );
        CREATE INDEX IF NOT EXISTS idx_spend_entity ON spend_ledger(entity_type, entity_id, period DESC);
    ]])
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
    if not lcols.trace_id               then ldb:exec("ALTER TABLE request_log ADD COLUMN trace_id               TEXT") end
    if not lcols.trace_id then ldb:exec("CREATE INDEX IF NOT EXISTS idx_log_trace_id ON request_log(trace_id)") end
    ldb:close()

    -- Semantic cache table (idempotent)
    local ldb2 = open_db(cfg.sqlite.logs_db)
    ldb2:exec([[
        CREATE TABLE IF NOT EXISTS semantic_cache (
            id            TEXT    PRIMARY KEY,
            gateway_id    TEXT    NOT NULL,
            model         TEXT    NOT NULL,
            prompt_hash   TEXT    NOT NULL,
            embedding     TEXT    NOT NULL,
            response_body TEXT    NOT NULL,
            cost_usd      REAL    NOT NULL DEFAULT 0,
            created_at    INTEGER NOT NULL,
            expires_at    INTEGER NOT NULL DEFAULT 0,
            hit_count     INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_semantic_cache_gw_model
            ON semantic_cache(gateway_id, model, created_at DESC);
    ]])
    ldb2:close()

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
    -- Add source column for gateway-level tracing (idempotent)
    local pgt_cols = {}
    for row in cfg_db2:nrows("PRAGMA table_info(playground_trace)") do pgt_cols[row.name] = true end
    if not pgt_cols.source then
        cfg_db2:exec("ALTER TABLE playground_trace ADD COLUMN source TEXT NOT NULL DEFAULT 'playground'")
    end
    -- SIEM config column on tenant (idempotent)
    local tcols = {}
    for row in cfg_db2:nrows("PRAGMA table_info(tenant)") do tcols[row.name] = true end
    if not tcols.siem_config then
        cfg_db2:exec("ALTER TABLE tenant ADD COLUMN siem_config TEXT")
    end
    -- Audit log table (idempotent)
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS audit_log (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER) * 1000),
            actor_ip   TEXT,
            method     TEXT NOT NULL,
            path       TEXT NOT NULL,
            status     INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);
    ]])
    -- actor_id column (added with auth sprint)
    local acols = {}
    for row in cfg_db2:nrows("PRAGMA table_info(audit_log)") do acols[row.name] = true end
    if not acols.actor_id then
        cfg_db2:exec("ALTER TABLE audit_log ADD COLUMN actor_id TEXT")
    end

    -- Flat permission model migration: move users from org-scoped to tenant-scoped.
    -- Idempotency guard: only run if user table still has organization_id column.
    local ucols2 = {}
    for row in cfg_db2:nrows("PRAGMA table_info(user)") do ucols2[row.name] = true end
    if ucols2["organization_id"] then
        cfg_db2:exec("PRAGMA foreign_keys = OFF")
        cfg_db2:exec([[
            BEGIN;
            CREATE TABLE user_flat (
                id         TEXT PRIMARY KEY,
                tenant_id  TEXT REFERENCES tenant(id) ON DELETE CASCADE,
                email      TEXT NOT NULL UNIQUE,
                name       TEXT,
                role       TEXT NOT NULL DEFAULT 'member',
                deleted_at INTEGER,
                created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
            );
            INSERT OR IGNORE INTO user_flat (id, tenant_id, email, name, role, deleted_at, created_at)
                SELECT u.id,
                       (SELECT t.id FROM tenant t WHERE t.organization_id = u.organization_id
                        AND t.deleted_at IS NULL LIMIT 1) AS tenant_id,
                       u.email, u.name,
                       CASE u.role WHEN 'org_admin' THEN 'tenant_admin' ELSE u.role END,
                       u.deleted_at, u.created_at
                FROM user u;
            DROP TABLE user;
            ALTER TABLE user_flat RENAME TO user;
            COMMIT;
        ]])
        cfg_db2:exec("PRAGMA foreign_keys = ON")
        -- Remove organization_id from tenant (recreate without it)
        cfg_db2:exec("PRAGMA foreign_keys = OFF")
        cfg_db2:exec([[
            BEGIN;
            CREATE TABLE tenant_flat (
                id            TEXT PRIMARY KEY,
                slug          TEXT UNIQUE NOT NULL,
                plan          TEXT NOT NULL DEFAULT 'free',
                budget_usd    REAL,
                budget_period TEXT NOT NULL DEFAULT 'monthly',
                siem_config   TEXT,
                deleted_at    INTEGER,
                created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
            );
            INSERT OR IGNORE INTO tenant_flat
                SELECT id, slug, plan, budget_usd, budget_period, siem_config, deleted_at, created_at
                FROM tenant;
            DROP TABLE tenant;
            ALTER TABLE tenant_flat RENAME TO tenant;
            COMMIT;
        ]])
        cfg_db2:exec("PRAGMA foreign_keys = ON")
        -- Drop organization table (no longer needed)
        cfg_db2:exec("DROP TABLE IF EXISTS organization")
        ngx.log(ngx.NOTICE, "storage: flat permission model migration complete")
    end

    -- Email OTP table
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS email_otp (
            id         TEXT PRIMARY KEY,
            email      TEXT NOT NULL,
            code_hash  TEXT NOT NULL,
            expires_at INTEGER NOT NULL,
            used_at    INTEGER,
            ip_addr    TEXT,
            created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
        );
        CREATE INDEX IF NOT EXISTS idx_otp_email ON email_otp(email, expires_at);
    ]])

    -- OAuth link table
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS oauth_link (
            user_id  TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            subject  TEXT NOT NULL,
            email    TEXT,
            PRIMARY KEY (provider, subject)
        );
    ]])

    -- user_gateway_access table (kept for backwards compat, no longer enforced)
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS user_gateway_access (
            user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
            gateway_id TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
            PRIMARY KEY (user_id, gateway_id)
        );
    ]])

    -- Chat tables
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS chat_conversation (
            id            TEXT    PRIMARY KEY,
            user_id       TEXT    NOT NULL REFERENCES user(id) ON DELETE CASCADE,
            gateway_id    TEXT    NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
            title         TEXT    NOT NULL DEFAULT 'New conversation',
            model         TEXT    NOT NULL DEFAULT '',
            system_prompt TEXT,
            temperature   REAL    DEFAULT 0.7,
            max_tokens    INTEGER DEFAULT 2048,
            created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            updated_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            deleted_at    INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_chat_conv_user ON chat_conversation(user_id, updated_at DESC);

        CREATE TABLE IF NOT EXISTS chat_message (
            id                TEXT    PRIMARY KEY,
            conversation_id   TEXT    NOT NULL REFERENCES chat_conversation(id) ON DELETE CASCADE,
            parent_message_id TEXT,
            role              TEXT    NOT NULL,
            content           TEXT    NOT NULL,
            input_tokens      INTEGER,
            output_tokens     INTEGER,
            cost_usd          REAL,
            latency_ms        INTEGER,
            gateway_id        TEXT,
            created_at        INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            deleted_at        INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_chat_msg_conv_ts ON chat_message(conversation_id, created_at);

        CREATE TABLE IF NOT EXISTS chat_attachment (
            id         TEXT    PRIMARY KEY,
            message_id TEXT    NOT NULL REFERENCES chat_message(id) ON DELETE CASCADE,
            filename   TEXT    NOT NULL,
            mime_type  TEXT    NOT NULL,
            size_bytes INTEGER NOT NULL,
            data       TEXT    NOT NULL,
            created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
        );
        CREATE INDEX IF NOT EXISTS idx_chat_att_msg ON chat_attachment(message_id);

        CREATE TABLE IF NOT EXISTS chat_preset (
            id            TEXT    PRIMARY KEY,
            user_id       TEXT    NOT NULL REFERENCES user(id) ON DELETE CASCADE,
            name          TEXT    NOT NULL,
            model         TEXT    NOT NULL DEFAULT '',
            system_prompt TEXT,
            temperature   REAL,
            max_tokens    INTEGER,
            created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            updated_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
        );
        CREATE INDEX IF NOT EXISTS idx_chat_preset_user ON chat_preset(user_id);
    ]])

    -- Projects tables (idempotent: CREATE TABLE IF NOT EXISTS)
    cfg_db2:exec([[
        CREATE TABLE IF NOT EXISTS chat_project (
            id                 TEXT    PRIMARY KEY,
            tenant_id          TEXT    NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
            name               TEXT    NOT NULL,
            description        TEXT,
            instructions       TEXT,
            icon               TEXT    NOT NULL DEFAULT '📁',
            color              TEXT    NOT NULL DEFAULT '#2563eb',
            default_gateway_id TEXT    REFERENCES gateway(id) ON DELETE SET NULL,
            default_model      TEXT,
            created_by         TEXT    NOT NULL REFERENCES user(id),
            created_at         INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            updated_at         INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            deleted_at         INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_chat_project_tenant
            ON chat_project(tenant_id, updated_at DESC) WHERE deleted_at IS NULL;

        CREATE TABLE IF NOT EXISTS chat_project_member (
            project_id TEXT NOT NULL REFERENCES chat_project(id) ON DELETE CASCADE,
            user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
            role       TEXT NOT NULL DEFAULT 'viewer',
            invited_by TEXT REFERENCES user(id),
            joined_at  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            PRIMARY KEY (project_id, user_id)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_proj_member_user
            ON chat_project_member(user_id);

        CREATE TABLE IF NOT EXISTS chat_project_knowledge (
            id             TEXT    PRIMARY KEY,
            project_id     TEXT    NOT NULL REFERENCES chat_project(id) ON DELETE CASCADE,
            filename       TEXT    NOT NULL,
            content_type   TEXT    NOT NULL DEFAULT 'text/plain',
            size_bytes     INTEGER NOT NULL DEFAULT 0,
            extracted_text TEXT    NOT NULL DEFAULT '',
            token_count    INTEGER NOT NULL DEFAULT 0,
            created_by     TEXT    NOT NULL REFERENCES user(id),
            created_at     INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
            UNIQUE(project_id, filename)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_proj_know_project
            ON chat_project_knowledge(project_id, created_at);
    ]])

    -- Add project_id + override columns to chat_conversation (idempotent)
    local conv_cols = {}
    for row in cfg_db2:nrows("PRAGMA table_info(chat_conversation)") do conv_cols[row.name] = true end
    if not conv_cols.project_id          then cfg_db2:exec("ALTER TABLE chat_conversation ADD COLUMN project_id          TEXT REFERENCES chat_project(id) ON DELETE SET NULL") end
    if not conv_cols.gateway_id_override then cfg_db2:exec("ALTER TABLE chat_conversation ADD COLUMN gateway_id_override TEXT") end
    if not conv_cols.model_override      then cfg_db2:exec("ALTER TABLE chat_conversation ADD COLUMN model_override      TEXT") end

    -- Add model column to chat_message if absent (older deployments)
    local msg_cols2 = {}
    for row in cfg_db2:nrows("PRAGMA table_info(chat_message)") do msg_cols2[row.name] = true end
    if not msg_cols2.model then cfg_db2:exec("ALTER TABLE chat_message ADD COLUMN model TEXT") end

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

    -- Even when the column type is already INTEGER, SQLite's dynamic typing
    -- allows ISO-string values to slip in (e.g. from an old logger version).
    -- Repair any such rows so strftime(ts/1000) always returns a valid date.
    ldb:exec([[
        UPDATE request_log
        SET ts = CAST(strftime('%s', ts) AS INTEGER) * 1000
        WHERE typeof(ts) = 'text'
    ]])
    ldb:exec([[
        UPDATE client_error_log
        SET ts = CAST(strftime('%s', ts) AS INTEGER) * 1000
        WHERE typeof(ts) = 'text'
    ]])
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
               t.budget_usd AS tenant_budget_usd,
               t.budget_period AS tenant_budget_period,
               t.siem_config AS tenant_siem_config
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  t.slug = ? AND g.slug = ? AND t.deleted_at IS NULL
        LIMIT 1
    ]], tenant_slug, gateway_slug)

    if err then return nil, err end
    if not row then return nil, "not_found" end

    local config = json.decode(row.config or "{}") or {}
    config.tenant_id            = row.tenant_id
    config.gateway_id           = row.gateway_id
    config.tenant_budget_usd    = row.tenant_budget_usd     -- nil when uncapped
    config.tenant_budget_period = row.tenant_budget_period or "monthly"
    -- Apply tenant-level SIEM config as fallback (gateway.config.siem takes priority)
    if not config.siem and row.tenant_siem_config then
        config.siem = json.decode(row.tenant_siem_config)
    end
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
        SELECT id, scopes, expires_at, user_id, label, rate_limit, budget_usd, budget_period
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
             token_quota_remaining, tenant_quota_remaining, trace_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        f.tenant_quota_remaining,
        f.trace_id
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

function M.upsert_tenant(slug, plan, budget_usd, budget_period, siem_config, chat_presets_config)
    local id = uuid()
    exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO tenant (id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config) VALUES (?,?,?,?,?,?,?)
    ]], id, slug, plan or "free", budget_usd, budget_period or "monthly", siem_config, chat_presets_config)
    local row = query_one(cfg_db(), "SELECT id FROM tenant WHERE slug = ?", slug)
    return row and row.id
end

function M.update_tenant(id, plan, budget_usd, budget_period, siem_config, chat_presets_config)
    return exec_one(cfg_db(), [[
        UPDATE tenant SET plan = COALESCE(?, plan), budget_usd = ?,
               budget_period = COALESCE(?, budget_period),
               siem_config = COALESCE(?, siem_config),
               chat_presets_config = COALESCE(?, chat_presets_config)
        WHERE id = ?
    ]], plan, budget_usd, budget_period, siem_config, chat_presets_config, id)
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
    local existing = query_one(cfg_db(), "SELECT id FROM user WHERE email = ? AND deleted_at IS NULL LIMIT 1", email)
    if existing then return nil, "email already in use" end
    local err = exec_one(cfg_db(), [[
        INSERT INTO user (id, tenant_id, email, name, role)
        VALUES (?,?,?,?,?)
    ]], id, tenant_id, email, name, role or "member")
    if err then return nil, err end
    return id
end

function M.update_user(id, email, name, role, tenant_id)
    if tenant_id ~= nil then
        return exec_one(cfg_db(), [[
            UPDATE user SET email = ?, name = ?, role = ?, tenant_id = ? WHERE id = ?
        ]], email, name, role, tenant_id, id)
    end
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

function M.get_tenant(id)
    return query_one(cfg_db(), [[
        SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config,
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
        FROM tenant WHERE id = ? AND deleted_at IS NULL
    ]], id)
end

function M.list_tenants(tenant_id_filter)
    if tenant_id_filter then
        return query_all(cfg_db(), [[
            SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config,
                   strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at
            FROM tenant WHERE deleted_at IS NULL AND id = ?
            ORDER BY created_at DESC
        ]], tenant_id_filter) or {}
    end
    return query_all(cfg_db(), [[
        SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config,
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
               strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch') AS created_at,
               CASE WHEN last_login_at IS NOT NULL
                    THEN strftime('%Y-%m-%dT%H:%M:%SZ', last_login_at, 'unixepoch') END AS last_login_at
        FROM user WHERE id = ?
    ]], id)
end

local USER_SORT_COLS = {
    email         = "u.email",
    name          = "COALESCE(u.name, '')",
    role          = "u.role",
    tenant        = "COALESCE(t.slug, '')",
    last_login_at = "COALESCE(u.last_login_at, 0)",
    created_at    = "u.created_at",
}

function M.list_users(tenant_id, opts)
    opts = opts or {}
    local col = USER_SORT_COLS[opts.sort] or "u.email"
    local dir = (opts.dir == "desc") and "DESC" or "ASC"
    local order = col .. " " .. dir
    if tenant_id then
        return query_all(cfg_db(), string.format([[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   t.slug AS tenant_slug,
                   strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', u.created_at, 'unixepoch') AS created_at,
                   CASE WHEN u.last_login_at IS NOT NULL
                        THEN strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', u.last_login_at, 'unixepoch') END AS last_login_at
            FROM user u
            LEFT JOIN tenant t ON t.id = u.tenant_id
            WHERE u.tenant_id = ? AND u.deleted_at IS NULL
            ORDER BY %s
        ]], order), tenant_id) or {}
    end
    return query_all(cfg_db(), string.format([[
        SELECT u.id, u.tenant_id, u.email, u.name, u.role,
               t.slug AS tenant_slug,
               strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', u.created_at, 'unixepoch') AS created_at,
               CASE WHEN u.last_login_at IS NOT NULL
                    THEN strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', u.last_login_at, 'unixepoch') END AS last_login_at
        FROM user u
        LEFT JOIN tenant t ON t.id = u.tenant_id
        WHERE u.deleted_at IS NULL
        ORDER BY %s
    ]], order)) or {}
end

function M.touch_last_login(user_id)
    exec_one(cfg_db(),
        "UPDATE user SET last_login_at = CAST(strftime('%s','now') AS INTEGER) WHERE id = ?",
        user_id)
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

-- ---------------------------------------------------------------------------
-- Spend ledger (period-aware budget tracking)
-- ---------------------------------------------------------------------------

-- Atomically add `micro` (USD * 1e6) to the spend for a given entity+period.
function M.incr_spend(entity_type, entity_id, period, micro)
    return exec_one(cfg_db(), [[
        INSERT INTO spend_ledger (entity_type, entity_id, period, amount_micro, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(entity_type, entity_id, period) DO UPDATE SET
            amount_micro = amount_micro + excluded.amount_micro,
            updated_at   = excluded.updated_at
    ]], entity_type, entity_id, period, micro, os.time())
end

-- Return the current spend for an entity+period as micro-dollars (INTEGER).
function M.get_spend(entity_type, entity_id, period)
    local row = query_one(cfg_db(), [[
        SELECT amount_micro FROM spend_ledger
        WHERE entity_type = ? AND entity_id = ? AND period = ?
    ]], entity_type, entity_id, period)
    return row and row.amount_micro or 0
end

-- Return all spend periods for an entity, newest first (for history display).
function M.get_spend_history(entity_type, entity_id, limit)
    return query_all(cfg_db(), [[
        SELECT period, amount_micro, updated_at
        FROM spend_ledger
        WHERE entity_type = ? AND entity_id = ?
        ORDER BY period DESC
        LIMIT ?
    ]], entity_type, entity_id, limit or 12) or {}
end

-- Delete spend records: if period given, deletes only that period; otherwise all periods.
function M.reset_spend(entity_type, entity_id, period)
    if period then
        return exec_one(cfg_db(), [[
            DELETE FROM spend_ledger WHERE entity_type = ? AND entity_id = ? AND period = ?
        ]], entity_type, entity_id, period)
    end
    return exec_one(cfg_db(), [[
        DELETE FROM spend_ledger WHERE entity_type = ? AND entity_id = ?
    ]], entity_type, entity_id)
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
               detectors_fired, scrub_applied, response_raw, trace_id
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

function M.get_usage_stats(tenant_id)
    local ldb = log_db()

    -- Period thresholds in milliseconds
    local now          = math.floor(ngx.now())
    local today_ms     = (now - (now % 86400)) * 1000
    local yesterday_ms = today_ms - 86400 * 1000
    local last_7d_ms   = today_ms - 7 * 86400 * 1000
    local hour_ms      = (now - 3600) * 1000
    local last_min_ms  = (now - 60) * 1000

    -- Optional tenant filter: validate UUID format then build SQL clause
    local tenant_clause = ""
    if tenant_id and tenant_id ~= "" then
        if not tenant_id:match("^[0-9a-fA-F%-]+$") then tenant_id = nil
        else tenant_clause = " AND tenant_id = '" .. tenant_id .. "'" end
    end

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

    local all_sql = string.format("SELECT %s, %s, %s, %s, %s FROM request_log WHERE ts >= %d%s",
        pcols("lm", "ts >= " .. last_min_ms),
        pcols("hr", "ts >= " .. hour_ms),
        pcols("td", "ts >= " .. today_ms),
        pcols("yd", "ts >= " .. yesterday_ms .. " AND ts < " .. today_ms),
        pcols("l7", "1=1"),
        last_7d_ms, tenant_clause)

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
    local by_tenant_sql = string.format([[
        SELECT r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               COUNT(*) AS requests,
               COALESCE(SUM(r.input_tokens),0)  AS input_tokens,
               COALESCE(SUM(r.output_tokens),0) AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4) AS cost_usd
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        WHERE r.ts >= %d%s
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], today_ms, tenant_clause)
    local by_tenant = query_all(ldb, by_tenant_sql) or {}

    local recent_sql = string.format([[
        SELECT strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', r.ts/1000, 'unixepoch') AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.gateway_id, COALESCE(g.slug, r.gateway_id) AS gateway,
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
        LEFT JOIN cfg.gateway g ON g.id = r.gateway_id
        %s
        ORDER BY r.ts DESC LIMIT 10
    ]], tenant_clause ~= "" and ("WHERE 1=1" .. tenant_clause) or "")
    local recent = query_all(ldb, recent_sql) or {}

    local recent_blocked_sql = string.format([[
        SELECT strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', r.ts/1000, 'unixepoch') AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.blocked_by, r.block_reason, r.latency_ms,
               r.guardrail_latency_ms, r.guardrail_verdict,
               r.blocked, r.scrub_applied, r.detectors_fired,
               r.response_raw, r.prompt_scrubbed
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        WHERE (r.blocked = 1
           OR r.scrub_applied = 1
           OR (r.detectors_fired IS NOT NULL AND r.detectors_fired != '[]'))%s
        ORDER BY r.ts DESC LIMIT 20
    ]], tenant_clause)
    local recent_blocked = query_all(ldb, recent_blocked_sql) or {}

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
function M.get_stats_timeseries(bucket_sec, n, end_sec, tenant_id)
    local ldb      = log_db()
    local ref      = end_sec or math.floor(ngx.now())
    local bms      = bucket_sec * 1000   -- bucket size in milliseconds

    -- Align reference time to bucket boundary, compute window start
    local now_bucket_sec = math.floor(ref / bucket_sec) * bucket_sec
    local since_ms       = (now_bucket_sec - (n - 1) * bucket_sec) * 1000

    -- bms is embedded as a literal (not a bind param) to ensure SQLite uses
    -- integer division. Binding it as a Lua number causes real-number division,
    -- making every row its own unique bucket.
    local extra_clause = ""
    if tenant_id then
        extra_clause = " AND tenant_id = ?"
    end
    local sql = string.format([[
        SELECT (ts / %d) * %d AS bucket_ts,
               COUNT(*) AS requests,
               SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
               ROUND(COALESCE(SUM(cost_usd),0),6) AS cost_usd
        FROM request_log
        WHERE ts >= ?%s
        GROUP BY bucket_ts
        ORDER BY bucket_ts ASC
    ]], bms, bms, extra_clause)
    local rows
    if tenant_id then
        rows = query_all(ldb, sql, since_ms, tenant_id) or {}
    else
        rows = query_all(ldb, sql, since_ms) or {}
    end

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

    -- Usage by tenant (cfg.tenant ATTACHed to _log_db as "cfg")
    local by_tenant = query_all(ldb, [[
        SELECT r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               COUNT(*)                                                            AS requests,
               SUM(CASE WHEN r.blocked=1 OR r.scrub_applied=1 THEN 1 ELSE 0 END) AS blocked,
               SUM(CASE WHEN r.cached=1 THEN 1 ELSE 0 END)                        AS cached,
               COALESCE(SUM(r.input_tokens),0)                                    AS input_tokens,
               COALESCE(SUM(r.output_tokens),0)                                   AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4)                               AS cost_usd,
               ROUND(COALESCE(SUM(r.saved_cost_usd),0),4)                         AS saved_cost_usd,
               ROUND(AVG(CASE WHEN r.blocked=0 THEN r.latency_ms END),0)          AS avg_latency_ms,
               SUM(CASE WHEN r.status >= 400 THEN 1 ELSE 0 END)                   AS errors
        FROM request_log r
        LEFT JOIN cfg.tenant t ON t.id = r.tenant_id
        WHERE r.ts >= ?
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], from) or {}

    -- Usage by gateway
    local by_gateway = query_all(ldb, [[
        SELECT r.gateway_id, COALESCE(g.slug, r.gateway_id) AS gateway,
               COALESCE(t.slug, r.tenant_id) AS tenant,
               COUNT(*)                                                            AS requests,
               SUM(CASE WHEN r.blocked=1 OR r.scrub_applied=1 THEN 1 ELSE 0 END) AS blocked,
               SUM(CASE WHEN r.cached=1 THEN 1 ELSE 0 END)                        AS cached,
               COALESCE(SUM(r.input_tokens),0)                                    AS input_tokens,
               COALESCE(SUM(r.output_tokens),0)                                   AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4)                               AS cost_usd,
               ROUND(COALESCE(SUM(r.saved_cost_usd),0),4)                         AS saved_cost_usd,
               ROUND(AVG(CASE WHEN r.blocked=0 THEN r.latency_ms END),0)          AS avg_latency_ms,
               SUM(CASE WHEN r.status >= 400 THEN 1 ELSE 0 END)                   AS errors
        FROM request_log r
        LEFT JOIN cfg.gateway g ON g.id = r.gateway_id
        LEFT JOIN cfg.tenant  t ON t.id = r.tenant_id
        WHERE r.ts >= ?
        GROUP BY r.gateway_id ORDER BY cost_usd DESC
    ]], from) or {}

    -- Usage by authenticated user (user_id populated by auth middleware from token)
    local by_user = query_all(ldb, [[
        SELECT r.user_id, r.tenant_id,
               u.email,
               COUNT(*)                                                            AS requests,
               SUM(CASE WHEN r.blocked=1 OR r.scrub_applied=1 THEN 1 ELSE 0 END) AS blocked,
               SUM(CASE WHEN r.cached=1 THEN 1 ELSE 0 END)                        AS cached,
               COALESCE(SUM(r.input_tokens),0)                                    AS input_tokens,
               COALESCE(SUM(r.output_tokens),0)                                   AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4)                               AS cost_usd,
               ROUND(COALESCE(SUM(r.saved_cost_usd),0),4)                         AS saved_cost_usd,
               ROUND(AVG(CASE WHEN r.blocked=0 THEN r.latency_ms END),0)          AS avg_latency_ms,
               SUM(CASE WHEN r.status >= 400 THEN 1 ELSE 0 END)                   AS errors
        FROM request_log r
        LEFT JOIN cfg.user u ON u.id = r.user_id
        WHERE r.ts >= ? AND r.user_id IS NOT NULL
        GROUP BY r.user_id, r.tenant_id ORDER BY cost_usd DESC
        LIMIT 50
    ]], from) or {}

    return {
        percentiles = pct,
        top_models  = top_models,
        by_tenant   = by_tenant,
        by_gateway  = by_gateway,
        by_user     = by_user,
    }
end

-- Top models for a single tenant, used by the per-tenant analytics detail panel.
function M.get_tenant_top_models(tenant_id, since_ms)
    local ldb  = log_db()
    local from = since_ms or (math.floor(ngx.now() * 1000) - 86400 * 1000)
    return query_all(ldb, [[
        SELECT model, provider,
               COUNT(*) AS requests,
               ROUND(COALESCE(SUM(cost_usd),0),4) AS cost_usd,
               ROUND(COALESCE(AVG(latency_ms),0))  AS avg_latency_ms
        FROM request_log
        WHERE ts >= ? AND tenant_id = ?
        GROUP BY provider, model
        ORDER BY requests DESC
        LIMIT 10
    ]], from, tenant_id) or {}
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
-- Audit log
-- ---------------------------------------------------------------------------

function M.insert_audit_log(actor_ip, method, path, status, actor_id)
    -- Best-effort: ignore errors so audit failures never affect the response.
    pcall(exec_one, cfg_db(), [[
        INSERT INTO audit_log (actor_ip, actor_id, method, path, status)
        VALUES (?, ?, ?, ?, ?)
    ]], actor_ip, actor_id, method, path, status)
end

function M.list_audit_logs(limit, offset)
    limit  = math.min(limit or 100, 500)
    offset = offset or 0
    return query_all(cfg_db(), [[
        SELECT id,
               strftime('%Y-%m-%dT%H:%M:%SZ', ts/1000, 'unixepoch') AS ts,
               actor_id, actor_ip, method, path, status
        FROM   audit_log
        ORDER  BY id DESC
        LIMIT  ? OFFSET ?
    ]], limit, offset)
end

-- ---------------------------------------------------------------------------
-- Playground trace API
-- ---------------------------------------------------------------------------

function M.create_playground_trace(id, gateway_id, model)
    return exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO playground_trace (id, gateway_id, model, source)
        VALUES (?, ?, ?, 'playground')
    ]], id, gateway_id, model)
end

-- Create a gateway-level request trace (source = 'gateway')
function M.create_trace(id, gateway_id, model, source)
    return exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO playground_trace (id, gateway_id, model, source)
        VALUES (?, ?, ?, ?)
    ]], id, gateway_id, model, source or "gateway")
end

-- List recent gateway traces for a gateway
function M.list_gateway_traces(gateway_id, limit)
    limit = math.min(limit or 50, 200)
    return query_all(cfg_db(), string.format([[
        SELECT id, model, created_at, completed_at, status, error, source
        FROM   playground_trace
        WHERE  gateway_id = ? AND source = 'gateway'
        ORDER  BY created_at DESC
        LIMIT  %d
    ]], limit), gateway_id) or {}
end

-- Purge gateway traces older than retention_sec seconds (uses os.time())
function M.purge_old_traces(retention_sec)
    local cutoff = os.time() - (retention_sec or 86400)
    exec_one(cfg_db(), [[
        DELETE FROM playground_trace WHERE source = 'gateway' AND created_at < ?
    ]], cutoff)
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

-- ---------------------------------------------------------------------------
-- Semantic cache storage
-- ---------------------------------------------------------------------------

function M.insert_semantic_cache(entry)
    -- INSERT OR IGNORE so duplicate prompt_hash entries are silently skipped
    return exec_one(log_db(), [[
        INSERT OR IGNORE INTO semantic_cache
            (id, gateway_id, model, prompt_hash, embedding,
             response_body, cost_usd, created_at, expires_at, hit_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
    ]], entry.id, entry.gateway_id, entry.model, entry.prompt_hash,
        entry.embedding, entry.response_body, entry.cost_usd or 0,
        entry.created_at, entry.expires_at or 0)
end

function M.find_semantic_candidates(gateway_id, model, limit)
    limit = math.min(limit or 100, 500)
    local now = math.floor(ngx.now())
    return query_all(log_db(), string.format([[
        SELECT id, embedding, response_body, cost_usd
        FROM semantic_cache
        WHERE gateway_id = ? AND model = ?
          AND (expires_at = 0 OR expires_at > ?)
        ORDER BY created_at DESC
        LIMIT %d
    ]], limit), gateway_id, model, now)
end

function M.increment_semantic_hit(id)
    return exec_one(log_db(), [[
        UPDATE semantic_cache SET hit_count = hit_count + 1 WHERE id = ?
    ]], id)
end

-- ---------------------------------------------------------------------------
-- Admin user lookup
-- ---------------------------------------------------------------------------

-- Returns the active user with the given email (any role can log in).
function M.find_admin_user_by_email(email)
    return query_one(cfg_db(), [[
        SELECT id, email, name, role, tenant_id
        FROM user
        WHERE email = ? AND deleted_at IS NULL
        LIMIT 1
    ]], email)
end

-- Bootstrap: create the first admin user if none exists and env var is set.
function M.bootstrap_admin()
    local email = os.getenv("AIG_BOOTSTRAP_ADMIN_EMAIL")
    if not email or email == "" then return end

    local existing = query_one(cfg_db(), [[
        SELECT id FROM user WHERE role = 'admin' AND deleted_at IS NULL LIMIT 1
    ]])
    if existing then return end  -- already have an admin

    local id = uuid_lib.v4()
    local name = os.getenv("AIG_BOOTSTRAP_ADMIN_NAME") or "Admin"
    exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO user (id, tenant_id, email, name, role)
        VALUES (?, NULL, ?, ?, 'admin')
    ]], id, email, name)
    ngx.log(ngx.NOTICE, "auth: bootstrap admin created — ", email,
            " — use email OTP or Google SSO to log in")
end

-- ---------------------------------------------------------------------------
-- Email OTP
-- ---------------------------------------------------------------------------

function M.insert_email_otp(id, email, code_hash, expires_at, ip_addr)
    -- Purge stale OTPs for this email first (best-effort)
    pcall(exec_one, cfg_db(), [[
        DELETE FROM email_otp WHERE email = ? AND (used_at IS NOT NULL OR expires_at < ?)
    ]], email, os.time())
    return exec_one(cfg_db(), [[
        INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES (?,?,?,?,?)
    ]], id, email, code_hash, expires_at, ip_addr)
end

-- Validate and consume an OTP. Returns nil on success, error string on failure.
function M.consume_email_otp(email, code_hash)
    local row = query_one(cfg_db(), [[
        SELECT id FROM email_otp
        WHERE email = ? AND code_hash = ? AND used_at IS NULL AND expires_at > ?
        LIMIT 1
    ]], email, code_hash, os.time())
    if not row then return "invalid or expired code" end
    exec_one(cfg_db(), [[
        UPDATE email_otp SET used_at = ? WHERE id = ?
    ]], os.time(), row.id)
    return nil
end

-- ---------------------------------------------------------------------------
-- OAuth links
-- ---------------------------------------------------------------------------

function M.upsert_oauth_link(user_id, provider, subject, email)
    return exec_one(cfg_db(), [[
        INSERT OR REPLACE INTO oauth_link (user_id, provider, subject, email)
        VALUES (?,?,?,?)
    ]], user_id, provider, subject, email)
end

function M.get_user_by_oauth(provider, subject)
    return query_one(cfg_db(), [[
        SELECT u.id, u.email, u.name, u.role, u.tenant_id
        FROM oauth_link l
        JOIN user u ON u.id = l.user_id
        WHERE l.provider = ? AND l.subject = ? AND u.deleted_at IS NULL
        LIMIT 1
    ]], provider, subject)
end

-- ---------------------------------------------------------------------------
-- Chat: conversations
-- ---------------------------------------------------------------------------

function M.list_conversations(user_id, limit, offset)
    limit  = math.min(limit or 50, 200)
    offset = offset or 0
    return query_all(cfg_db(), string.format([[
        SELECT id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at,
               datetime(updated_at, 'unixepoch') || 'Z' AS updated_at
        FROM chat_conversation
        WHERE user_id = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC
        LIMIT %d OFFSET %d
    ]], limit, offset), user_id) or setmetatable({}, cjson.array_mt)
end

function M.create_conversation(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_conversation
            (id, user_id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ]], id, data.user_id, data.gateway_id,
        data.project_id,
        data.title or "New conversation",
        data.model or "",
        data.system_prompt,
        data.temperature or 0.7,
        data.max_tokens or 2048,
        now, now)
    if e then return nil, e end
    return id
end

function M.get_conversation(id, user_id)
    local conv = query_one(cfg_db(), [[
        SELECT id, user_id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at,
               datetime(updated_at, 'unixepoch') || 'Z' AS updated_at
        FROM chat_conversation WHERE id = ? AND user_id = ? AND deleted_at IS NULL LIMIT 1
    ]], id, user_id)
    if not conv then return nil, "not_found" end
    local msgs = query_all(cfg_db(), [[
        SELECT id, parent_message_id, role, content,
               input_tokens, output_tokens, cost_usd, latency_ms, gateway_id,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at
        FROM chat_message WHERE conversation_id = ? AND deleted_at IS NULL ORDER BY created_at ASC
    ]], id) or {}
    for _, m in ipairs(msgs) do m.attachments = setmetatable({}, cjson.array_mt) end
    if #msgs > 0 then
        local msg_idx = {}
        local ids = {}
        for _, m in ipairs(msgs) do
            msg_idx[m.id] = m
            ids[#ids+1] = "'" .. m.id:gsub("'", "''") .. "'"
        end
        local atts = query_all(cfg_db(), string.format([[
            SELECT id, message_id, filename, mime_type, size_bytes,
                   datetime(created_at, 'unixepoch') || 'Z' AS created_at
            FROM chat_attachment WHERE message_id IN (%s)
        ]], table.concat(ids, ","))) or {}
        for _, att in ipairs(atts) do
            local m = msg_idx[att.message_id]
            if m then m.attachments[#m.attachments+1] = att end
        end
    end
    conv.messages = setmetatable(msgs, cjson.array_mt)
    return conv
end

function M.update_conversation(id, user_id, data)
    local sets, params = {}, {}
    if data.title         ~= nil then sets[#sets+1] = "title = ?";         params[#params+1] = data.title end
    if data.model         ~= nil then sets[#sets+1] = "model = ?";         params[#params+1] = data.model end
    if data.system_prompt ~= nil then sets[#sets+1] = "system_prompt = ?"; params[#params+1] = data.system_prompt end
    if data.temperature   ~= nil then sets[#sets+1] = "temperature = ?";   params[#params+1] = data.temperature end
    if data.max_tokens    ~= nil then sets[#sets+1] = "max_tokens = ?";    params[#params+1] = data.max_tokens end
    if data.gateway_id    ~= nil then sets[#sets+1] = "gateway_id = ?";    params[#params+1] = data.gateway_id end
    if #sets == 0 then return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = os.time()
    params[#params+1] = id
    params[#params+1] = user_id
    return exec_one(cfg_db(),
        "UPDATE chat_conversation SET " .. table.concat(sets, ", ") ..
        " WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
        table.unpack(params))
end

function M.delete_conversation(id, user_id)
    return exec_one(cfg_db(), [[
        UPDATE chat_conversation SET deleted_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL
    ]], os.time(), id, user_id)
end

-- ---------------------------------------------------------------------------
-- Chat: messages
-- ---------------------------------------------------------------------------

function M.append_message(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_message
            (id, conversation_id, parent_message_id, role, content,
             input_tokens, output_tokens, cost_usd, latency_ms, gateway_id, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ]], id, data.conversation_id, data.parent_message_id,
        data.role, data.content,
        data.input_tokens, data.output_tokens,
        data.cost_usd, data.latency_ms, data.gateway_id, now)
    if not e then
        exec_one(cfg_db(), "UPDATE chat_conversation SET updated_at = ? WHERE id = ?",
                 now, data.conversation_id)
    end
    if e then return nil, e end
    return id
end

function M.update_message(id, conversation_id, user_id, content)
    return exec_one(cfg_db(), [[
        UPDATE chat_message SET content = ?
        WHERE id = ? AND conversation_id = ?
          AND deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM chat_conversation c WHERE c.id = ? AND c.user_id = ?)
    ]], content, id, conversation_id, conversation_id, user_id)
end

function M.delete_message(id, conversation_id, user_id)
    return exec_one(cfg_db(), [[
        UPDATE chat_message SET deleted_at = ?
        WHERE id = ? AND conversation_id = ?
          AND deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM chat_conversation c WHERE c.id = ? AND c.user_id = ?)
    ]], os.time(), id, conversation_id, conversation_id, user_id)
end

-- ---------------------------------------------------------------------------
-- Chat: attachments
-- ---------------------------------------------------------------------------

function M.insert_attachment(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_attachment (id, message_id, filename, mime_type, size_bytes, data, created_at)
        VALUES (?,?,?,?,?,?,?)
    ]], id, data.message_id, data.filename, data.mime_type, data.size_bytes, data.data, now)
    if e then return nil, e end
    return id
end

function M.get_attachment(id, user_id)
    local row = query_one(cfg_db(), [[
        SELECT a.id, a.message_id, a.filename, a.mime_type, a.size_bytes, a.data,
               datetime(a.created_at, 'unixepoch') || 'Z' AS created_at
        FROM chat_attachment a
        JOIN chat_message m ON m.id = a.message_id
        JOIN chat_conversation c ON c.id = m.conversation_id
        WHERE a.id = ? AND c.user_id = ? LIMIT 1
    ]], id, user_id)
    if not row then return nil, "not_found" end
    return row
end

function M.delete_attachment(id, user_id)
    return exec_one(cfg_db(), [[
        DELETE FROM chat_attachment WHERE id = ?
          AND EXISTS (
            SELECT 1 FROM chat_message m
            JOIN chat_conversation c ON c.id = m.conversation_id
            WHERE m.id = chat_attachment.message_id AND c.user_id = ?
          )
    ]], id, user_id)
end

-- ---------------------------------------------------------------------------
-- Chat: presets
-- ---------------------------------------------------------------------------

function M.list_presets(user_id)
    return query_all(cfg_db(), [[
        SELECT id, name, model, system_prompt, temperature, max_tokens,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at,
               datetime(updated_at, 'unixepoch') || 'Z' AS updated_at
        FROM chat_preset WHERE user_id = ? ORDER BY name ASC
    ]], user_id) or setmetatable({}, cjson.array_mt)
end

function M.create_preset(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_preset
            (id, user_id, name, model, system_prompt, temperature, max_tokens, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], id, data.user_id, data.name, data.model or "",
        data.system_prompt, data.temperature, data.max_tokens, now, now)
    if e then return nil, e end
    return id
end

function M.update_preset(id, user_id, data)
    local sets, params = {}, {}
    if data.name          ~= nil then sets[#sets+1] = "name = ?";          params[#params+1] = data.name end
    if data.model         ~= nil then sets[#sets+1] = "model = ?";         params[#params+1] = data.model end
    if data.system_prompt ~= nil then sets[#sets+1] = "system_prompt = ?"; params[#params+1] = data.system_prompt end
    if data.temperature   ~= nil then sets[#sets+1] = "temperature = ?";   params[#params+1] = data.temperature end
    if data.max_tokens    ~= nil then sets[#sets+1] = "max_tokens = ?";    params[#params+1] = data.max_tokens end
    if #sets == 0 then return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = os.time()
    params[#params+1] = id
    params[#params+1] = user_id
    return exec_one(cfg_db(),
        "UPDATE chat_preset SET " .. table.concat(sets, ", ") .. " WHERE id = ? AND user_id = ?",
        table.unpack(params))
end

function M.delete_preset(id, user_id)
    return exec_one(cfg_db(), "DELETE FROM chat_preset WHERE id = ? AND user_id = ?", id, user_id)
end

-- ---------------------------------------------------------------------------
-- Chat: projects
-- ---------------------------------------------------------------------------

function M.list_projects(tenant_id, user_id, is_admin)
    if is_admin then
        return query_all(cfg_db(), [[
            SELECT p.id, p.name, p.description, p.icon, p.color,
                   p.default_gateway_id, p.default_model,
                   p.created_by,
                   datetime(p.created_at, 'unixepoch') || 'Z' AS created_at,
                   datetime(p.updated_at, 'unixepoch') || 'Z' AS updated_at,
                   (SELECT COUNT(*) FROM chat_project_member pm2 WHERE pm2.project_id = p.id) AS member_count,
                   (SELECT COUNT(*) FROM chat_project_knowledge pk WHERE pk.project_id = p.id) AS knowledge_count
            FROM chat_project p
            WHERE p.tenant_id = ? AND p.deleted_at IS NULL
            ORDER BY p.updated_at DESC
        ]], tenant_id) or setmetatable({}, cjson.array_mt)
    else
        return query_all(cfg_db(), [[
            SELECT p.id, p.name, p.description, p.icon, p.color,
                   p.default_gateway_id, p.default_model,
                   p.created_by, pm.role AS my_role,
                   datetime(p.created_at, 'unixepoch') || 'Z' AS created_at,
                   datetime(p.updated_at, 'unixepoch') || 'Z' AS updated_at,
                   (SELECT COUNT(*) FROM chat_project_member pm2 WHERE pm2.project_id = p.id) AS member_count,
                   (SELECT COUNT(*) FROM chat_project_knowledge pk WHERE pk.project_id = p.id) AS knowledge_count
            FROM chat_project p
            JOIN chat_project_member pm ON pm.project_id = p.id AND pm.user_id = ?
            WHERE p.tenant_id = ? AND p.deleted_at IS NULL
            ORDER BY p.updated_at DESC
        ]], user_id, tenant_id) or setmetatable({}, cjson.array_mt)
    end
end

function M.create_project(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_project
            (id, tenant_id, name, description, instructions, icon, color,
             default_gateway_id, default_model, created_by, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ]], id, data.tenant_id, data.name, data.description, data.instructions,
        data.icon or "📁", data.color or "#2563eb",
        data.default_gateway_id, data.default_model,
        data.created_by, now, now)
    if e then return nil, e end
    -- auto-add creator as owner
    local e2 = exec_one(cfg_db(), [[
        INSERT OR IGNORE INTO chat_project_member (project_id, user_id, role, joined_at)
        VALUES (?, ?, 'owner', ?)
    ]], id, data.created_by, now)
    if e2 then return nil, e2 end
    return id
end

function M.get_project(id, user_id, is_admin)
    local row
    if is_admin then
        row = query_one(cfg_db(), [[
            SELECT p.id, p.name, p.description, p.instructions, p.icon, p.color,
                   p.default_gateway_id, p.default_model, p.created_by,
                   datetime(p.created_at, 'unixepoch') || 'Z' AS created_at,
                   datetime(p.updated_at, 'unixepoch') || 'Z' AS updated_at
            FROM chat_project p
            WHERE p.id = ? AND p.deleted_at IS NULL LIMIT 1
        ]], id)
    else
        row = query_one(cfg_db(), [[
            SELECT p.id, p.name, p.description, p.instructions, p.icon, p.color,
                   p.default_gateway_id, p.default_model, p.created_by,
                   pm.role AS my_role,
                   datetime(p.created_at, 'unixepoch') || 'Z' AS created_at,
                   datetime(p.updated_at, 'unixepoch') || 'Z' AS updated_at
            FROM chat_project p
            JOIN chat_project_member pm ON pm.project_id = p.id AND pm.user_id = ?
            WHERE p.id = ? AND p.deleted_at IS NULL LIMIT 1
        ]], user_id, id)
    end
    if not row then return nil, "not_found" end
    -- attach members
    row.members = query_all(cfg_db(), [[
        SELECT pm.user_id, pm.role,
               u.email, u.name,
               datetime(pm.joined_at, 'unixepoch') || 'Z' AS joined_at
        FROM chat_project_member pm
        JOIN user u ON u.id = pm.user_id
        WHERE pm.project_id = ?
        ORDER BY pm.joined_at ASC
    ]], id) or setmetatable({}, cjson.array_mt)
    -- attach knowledge metadata (no text)
    row.knowledge = query_all(cfg_db(), [[
        SELECT id, filename, content_type, size_bytes, token_count,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at
        FROM chat_project_knowledge WHERE project_id = ?
        ORDER BY created_at ASC
    ]], id) or setmetatable({}, cjson.array_mt)
    return row
end

function M.update_project(id, data)
    local sets, params = {}, {}
    local allowed = {"name","description","instructions","icon","color","default_gateway_id","default_model"}
    for _, f in ipairs(allowed) do
        if data[f] ~= nil then
            sets[#sets+1]   = f .. " = ?"
            params[#params+1] = data[f]
        end
    end
    if #sets == 0 then return nil end
    sets[#sets+1]   = "updated_at = ?"
    params[#params+1] = os.time()
    params[#params+1] = id
    return exec_one(cfg_db(),
        "UPDATE chat_project SET " .. table.concat(sets, ", ") .. " WHERE id = ? AND deleted_at IS NULL",
        table.unpack(params))
end

function M.delete_project(id)
    local now = os.time()
    exec_one(cfg_db(), [[
        UPDATE chat_conversation SET project_id = NULL WHERE project_id = ?
    ]], id)
    return exec_one(cfg_db(), [[
        UPDATE chat_project SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL
    ]], now, id)
end

function M.get_project_member(project_id, user_id)
    return query_one(cfg_db(), [[
        SELECT project_id, user_id, role,
               datetime(joined_at, 'unixepoch') || 'Z' AS joined_at
        FROM chat_project_member WHERE project_id = ? AND user_id = ? LIMIT 1
    ]], project_id, user_id)
end

function M.add_project_member(project_id, user_id, role, invited_by)
    local now = os.time()
    return exec_one(cfg_db(), [[
        INSERT OR REPLACE INTO chat_project_member (project_id, user_id, role, invited_by, joined_at)
        VALUES (?, ?, ?, ?, ?)
    ]], project_id, user_id, role or "viewer", invited_by, now)
end

function M.update_project_member_role(project_id, user_id, role)
    return exec_one(cfg_db(), [[
        UPDATE chat_project_member SET role = ? WHERE project_id = ? AND user_id = ?
    ]], role, project_id, user_id)
end

function M.remove_project_member(project_id, user_id)
    return exec_one(cfg_db(), [[
        DELETE FROM chat_project_member WHERE project_id = ? AND user_id = ?
    ]], project_id, user_id)
end

function M.count_project_owners(project_id)
    local row = query_one(cfg_db(), [[
        SELECT COUNT(*) AS n FROM chat_project_member
        WHERE project_id = ? AND role = 'owner'
    ]], project_id)
    return row and row.n or 0
end

function M.list_project_knowledge(project_id)
    return query_all(cfg_db(), [[
        SELECT id, filename, content_type, size_bytes, token_count,
               created_by,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at
        FROM chat_project_knowledge WHERE project_id = ?
        ORDER BY created_at ASC
    ]], project_id) or setmetatable({}, cjson.array_mt)
end

function M.get_project_knowledge_text(project_id)
    return query_all(cfg_db(), [[
        SELECT id, filename, content_type, size_bytes, token_count, extracted_text,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at
        FROM chat_project_knowledge WHERE project_id = ?
        ORDER BY created_at ASC
    ]], project_id) or setmetatable({}, cjson.array_mt)
end

function M.add_project_knowledge(data)
    local id  = uuid_lib.v4()
    local now = os.time()
    local token_count = math.floor((#(data.extracted_text or "")) / 4)
    local e = exec_one(cfg_db(), [[
        INSERT INTO chat_project_knowledge
            (id, project_id, filename, content_type, size_bytes, extracted_text,
             token_count, created_by, created_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], id, data.project_id, data.filename, data.content_type or "text/plain",
        data.size_bytes or 0, data.extracted_text or "",
        token_count, data.created_by, now)
    if e then return nil, e end
    return id
end

function M.delete_project_knowledge(id, project_id)
    return exec_one(cfg_db(), [[
        DELETE FROM chat_project_knowledge WHERE id = ? AND project_id = ?
    ]], id, project_id)
end

function M.list_project_conversations(project_id, limit)
    limit = limit or 50
    return query_all(cfg_db(), [[
        SELECT id, title, model,
               datetime(created_at, 'unixepoch') || 'Z' AS created_at,
               datetime(updated_at, 'unixepoch') || 'Z' AS updated_at
        FROM chat_conversation
        WHERE project_id = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC LIMIT ?
    ]], project_id, limit) or setmetatable({}, cjson.array_mt)
end

return M

