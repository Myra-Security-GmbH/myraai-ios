-- storage/mysql.lua — MySQL 8.0+ backend (production replacement for sqlite.lua)
-- Uses lua-resty-mysql (bundled with OpenResty). Requires MySQL 8.0+ for
-- window functions used by get_analytics_depth().
--
-- Single database: all config and log tables in one schema.
-- No ATTACH needed — cross-table JOINs work directly.
--
-- Public interface: identical to storage/sqlite.lua (69 functions).

local mysql_lib = require("resty.mysql")
local cjson     = require("cjson.safe")
local json      = require("utils.json")
local uuid_lib  = require("utils.uuid")

local M = {}

local _cfg  -- set by M.init()

-- ---------------------------------------------------------------------------
-- Connection helpers
-- ---------------------------------------------------------------------------

-- Retry parameters for transient connection failures (pool exhaustion, brief
-- network blip, MySQL max_connections spike).
local CONN_RETRIES   = 3          -- attempts after the first failure
local CONN_RETRY_MS  = { 20, 50, 120 }  -- wait before each retry (ms)

local function get_conn()
    local connect_opts = {
        host            = _cfg.host     or "127.0.0.1",
        port            = _cfg.port     or 3306,
        database        = _cfg.database or "ai_gateway",
        user            = _cfg.user     or "gateway",
        password        = _cfg.password or "",
        charset         = "utf8mb4",
        max_packet_size = 1024 * 1024,
    }

    local last_err, last_errno, last_sqlstate
    for attempt = 1, CONN_RETRIES + 1 do
        local db, err = mysql_lib:new()
        if not db then return nil, "mysql:new: " .. tostring(err) end
        db:set_timeout(_cfg.pool_timeout or 10000)

        local ok, err2, errno, sqlstate = db:connect(connect_opts)
        if ok then return db end

        last_err, last_errno, last_sqlstate = err2, errno, sqlstate

        if attempt <= CONN_RETRIES then
            ngx.log(ngx.WARN, string.format(
                "mysql connect attempt %d/%d failed (%s) — retrying in %dms",
                attempt, CONN_RETRIES + 1, tostring(err2), CONN_RETRY_MS[attempt]))
            pcall(ngx.sleep, CONN_RETRY_MS[attempt] / 1000)
        end
    end

    return nil, string.format("mysql connect: %s (errno=%s sqlstate=%s)",
        tostring(last_err), tostring(last_errno), tostring(last_sqlstate))
end

local function release(db)
    if db then db:set_keepalive(0, _cfg.pool_size or 100) end
end

-- ---------------------------------------------------------------------------
-- Value escaping and parameter binding
-- ---------------------------------------------------------------------------

-- Escape a string value for safe interpolation into a MySQL string literal.
-- resty.mysql does not provide an escape method, so we implement it here.
local function escape_string(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub("%z",  "\\0")
    s = s:gsub("\n",  "\\n")
    s = s:gsub("\r",  "\\r")
    s = s:gsub("'",   "\\'")
    s = s:gsub('"',   '\\"')
    s = s:gsub("\26", "\\Z")
    return "'" .. s .. "'"
end

-- Escape a single value for safe interpolation into SQL.
local function esc(_, v)
    if v == nil then return "NULL" end
    local t = type(v)
    if t == "number"  then return tostring(v) end
    if t == "boolean" then return v and "1" or "0" end
    return escape_string(tostring(v))
end

-- Replace each `?` placeholder in sql with the next escaped argument.
local function bind(db, sql, ...)
    local args = {...}
    local i = 0
    return (sql:gsub("%?", function()
        i = i + 1
        return esc(db, args[i])
    end))
end

-- ---------------------------------------------------------------------------
-- Core query helpers (mirror sqlite.lua's query_one / query_all / exec_one)
-- ---------------------------------------------------------------------------

-- resty.mysql returns SQL NULL as ngx.null (userdata).  Convert to Lua nil so
-- callers can use simple truthiness checks without ngx.null surprises.
local null = ngx.null
local function nullify(row)
    if not row then return row end
    for k, v in pairs(row) do
        if v == null then row[k] = nil end
    end
    return row
end

-- resty.mysql uses MySQL's text protocol and returns every column value as a
-- Lua string, regardless of the declared SQL type.  Convert any string that
-- parses as a number back to a Lua number so that cjson serialises it as a
-- JSON number (unquoted) and the frontend receives the correct type.
-- Safe for this codebase: all text-typed identifiers (UUIDs, slugs, emails,
-- model names) are never purely numeric, so tonumber() returns nil for them.
local function coerce_numbers(row)
    if not row then return row end
    for k, v in pairs(row) do
        if type(v) == "string" then
            local n = tonumber(v)
            if n then row[k] = n end
        end
    end
    return row
end

local function query_one(db, sql, ...)
    local res, err = db:query(bind(db, sql, ...))
    if not res then return nil, err end
    return coerce_numbers(nullify(res[1]))
end

local function query_all(db, sql, ...)
    local res, err = db:query(bind(db, sql, ...))
    if not res then return setmetatable({}, cjson.array_mt), err end
    for i = 1, #res do res[i] = coerce_numbers(nullify(res[i])) end
    return setmetatable(res, cjson.array_mt)
end

-- Returns err string on failure, nil on success.
local function exec_one(db, sql, ...)
    local bound = bind(db, sql, ...)
    local res, err = db:query(bound)
    if not res then return err end
    return nil
end

-- ---------------------------------------------------------------------------
-- Module helpers
-- ---------------------------------------------------------------------------

local function uuid()
    return uuid_lib.v4()
end

local function migrations_dir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*/)") .. "migrations/"
end

-- Ordered list of all migrations. Append new entries here when adding a migration file.
local MIGRATIONS = {
    { version = "0001", file = "0001_initial_schema.sql",          description = "Initial schema" },
    { version = "0002", file = "0002_permission_model.sql",        description = "Missing columns and tables" },
    { version = "0003", file = "0003_add_rate_limited_to_request_log.sql", description = "Add rate_limited flag to request_log" },
    { version = "0004", file = "0004_add_compaction_triggered_to_request_log.sql", description = "Add compaction_triggered and compaction_tokens_before to request_log" },
    { version = "0005", file = "0005_add_conversation_sharing.sql",  description = "Add conversation sharing columns" },
    { version = "0006", file = "0006_add_conversation_summary.sql",   description = "Add conversation_summary table" },
    { version = "0007", file = "0007_add_mcp_and_cache_deletion.sql", description = "Add mcp_connector table and cache_deletion_tokens column" },
    { version = "0008", file = "0008_anthropic_usage.sql",            description = "Tenant-scoped provider keys and Anthropic usage snapshots" },
    { version = "0009", file = "0009_cache_write_1h.sql",             description = "1h cache write pricing in model_price and token split in request_log" },
}

-- Errors that mean "this change is already applied" — tolerated silently.
local IDEMPOTENT_ERRNOS = {
    [1050] = true,  -- Table 'x' already exists
    [1060] = true,  -- Duplicate column name
    [1061] = true,  -- Duplicate key name
    [1091] = true,  -- Can't DROP ...; check that column/key exists
    [1826] = true,  -- Duplicate foreign key constraint name
}

local function decode_detectors(row)
    if row.detectors_fired and row.detectors_fired ~= "" then
        row.detectors_fired = json.decode(row.detectors_fired) or {}
    else
        row.detectors_fired = {}
    end
end

-- ---------------------------------------------------------------------------
-- M.migrate — apply schema DDL (idempotent, call from init_by_lua_block)
-- ---------------------------------------------------------------------------

function M.migrate(cfg)
    local db, err = mysql_lib:new()
    if not db then error("mysql:new: " .. tostring(err)) end
    db:set_timeout(30000)
    local ok, err2 = db:connect({
        host     = cfg.mysql.host     or "127.0.0.1",
        port     = cfg.mysql.port     or 3306,
        database = cfg.mysql.database or "ai_gateway",
        user     = cfg.mysql.user     or "gateway",
        password = cfg.mysql.password or "",
        charset  = "utf8mb4",
    })
    if not ok then error("mysql migrate connect: " .. tostring(err2)) end

    -- Create the migration tracking table (idempotent).
    local res, e = db:query([[
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     VARCHAR(16)  NOT NULL,
            applied_at  BIGINT       NOT NULL,
            description VARCHAR(255) NOT NULL DEFAULT '',
            PRIMARY KEY (version)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    if not res then
        db:close()
        error("schema_migrations create failed: " .. tostring(e))
    end

    -- Fetch already-applied versions.
    local rows, e2 = db:query("SELECT version FROM schema_migrations ORDER BY version")
    if not rows then
        db:close()
        error("schema_migrations read failed: " .. tostring(e2))
    end
    local applied = {}
    for _, row in ipairs(rows) do applied[row.version] = true end

    -- Run the pre-migration Lua compatibility step: organization_id → tenant_id.
    -- This targets legacy installs only (guard: checks for the old column).
    -- Kept in Lua because it requires conditional multi-step logic that cannot
    -- be expressed as idempotent SQL without stored procedures.
    local check = db:query("SELECT COUNT(*) AS n FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='user' AND column_name='organization_id'")
    if check and check[1] and check[1].n and tonumber(check[1].n) > 0 then
        db:query("SET foreign_key_checks=0")
        db:query("ALTER TABLE `user` ADD COLUMN IF NOT EXISTS tenant_id_new VARCHAR(36) NULL")
        db:query("UPDATE `user` u JOIN tenant t ON t.organization_id = u.organization_id AND t.deleted_at IS NULL SET u.tenant_id_new = t.id WHERE u.organization_id IS NOT NULL")
        db:query("UPDATE `user` SET role='tenant_admin' WHERE role='org_admin'")
        db:query("ALTER TABLE `user` DROP FOREIGN KEY IF EXISTS fk_user_org")
        db:query("ALTER TABLE `user` DROP COLUMN IF EXISTS organization_id")
        db:query("ALTER TABLE `user` DROP COLUMN IF EXISTS tenant_id")
        db:query("ALTER TABLE `user` RENAME COLUMN tenant_id_new TO tenant_id")
        db:query("ALTER TABLE `user` ADD CONSTRAINT fk_user_tenant FOREIGN KEY (tenant_id) REFERENCES tenant(id) ON DELETE CASCADE")
        db:query("ALTER TABLE `user` DROP INDEX IF EXISTS uq_user_tenant_email")
        db:query("ALTER TABLE `user` ADD UNIQUE KEY uq_user_email (email)")
        db:query("ALTER TABLE tenant DROP FOREIGN KEY IF EXISTS fk_tenant_org")
        db:query("ALTER TABLE tenant DROP COLUMN IF EXISTS organization_id")
        db:query("DROP TABLE IF EXISTS organization")
        db:query("SET foreign_key_checks=1")
        ngx.log(ngx.NOTICE, "storage/mysql: flat permission model migration complete")
    end

    -- Apply pending migrations from the MIGRATIONS registry.
    local dir = migrations_dir()
    for _, m in ipairs(MIGRATIONS) do
        if not applied[m.version] then
            ngx.log(ngx.NOTICE, "storage/mysql: applying migration " .. m.version .. " (" .. m.description .. ")")
            local fh = io.open(dir .. m.file, "r")
            if not fh then
                db:close()
                error("migration file not found: " .. dir .. m.file)
            end
            local sql = fh:read("*a")
            fh:close()

            for stmt in sql:gmatch("([^;]+)") do
                stmt = stmt:gsub("%-%-[^\n]*", "")  -- strip line comments
                stmt = stmt:match("^%s*(.-)%s*$")   -- trim whitespace
                if stmt ~= "" then
                    local r, e3, errno = db:query(stmt)
                    if not r then
                        local en = tonumber(errno) or 0
                        if not IDEMPOTENT_ERRNOS[en] then
                            db:close()
                            error("migration " .. m.version .. " error: " .. tostring(e3) .. "\nSQL: " .. stmt:sub(1, 200))
                        end
                    end
                end
            end

            local ts = ngx.now and math.floor(ngx.now()) or os.time()
            local mr, me = db:query(bind(db,
                "INSERT IGNORE INTO schema_migrations (version, applied_at, description) VALUES (?, ?, ?)",
                m.version, ts, m.description
            ))
            if not mr then
                ngx.log(ngx.ERR, "storage/mysql: schema_migrations insert failed v=", m.version, " err=", tostring(me))
            end
            ngx.log(ngx.NOTICE, "storage/mysql: migration " .. m.version .. " applied")
        end
    end

    db:set_keepalive(0, 5)
end

-- ---------------------------------------------------------------------------
-- M.init — store config, verify connectivity (call from init_worker_by_lua_block)
-- ---------------------------------------------------------------------------

function M.init(cfg)
    _cfg = cfg.mysql
    -- Quick connectivity check
    local db, err = get_conn()
    if not db then
        ngx.log(ngx.ERR, "storage/mysql init: " .. tostring(err))
        return
    end
    local res = db:query("SELECT 1")
    release(db)
    if not res then
        ngx.log(ngx.ERR, "storage/mysql init: SELECT 1 failed")
    end
end

-- ---------------------------------------------------------------------------
-- Public read API
-- ---------------------------------------------------------------------------

function M.get_gateway(tenant_slug, gateway_slug)
    local db, err = get_conn()
    if not db then return nil, err end
    local row, e = query_one(db, [[
        SELECT t.id AS tenant_id, g.id AS gateway_id, g.config,
               t.budget_usd AS tenant_budget_usd,
               t.budget_period AS tenant_budget_period,
               t.siem_config AS tenant_siem_config
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  t.slug = ? AND g.slug = ? AND t.deleted_at IS NULL
        LIMIT 1
    ]], tenant_slug, gateway_slug)
    release(db)
    if e then return nil, e end
    if not row then return nil, "not_found" end

    local config = json.decode(row.config or "{}") or {}
    config.tenant_id            = row.tenant_id
    config.gateway_id           = row.gateway_id
    config.tenant_budget_usd    = row.tenant_budget_usd
    config.tenant_budget_period = row.tenant_budget_period or "monthly"
    if not config.siem and row.tenant_siem_config then
        config.siem = json.decode(row.tenant_siem_config)
    end
    return config
end

function M.get_provider_key(gateway_id, provider, alias)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return nil, nil, err end
    local row, e = query_one(db, [[
        SELECT encrypted_key, nonce FROM provider_config
        WHERE  gateway_id = ? AND provider = ? AND alias = ?
        LIMIT 1
    ]], gateway_id, provider, alias)
    release(db)
    if e then return nil, nil, e end
    if not row then return nil, nil, "not_found" end
    return row.encrypted_key, row.nonce
end

function M.get_auth_token(gateway_id, token_hash)
    local db, err = get_conn()
    if not db then return nil, err end
    local row, e = query_one(db, [[
        SELECT id, scopes, expires_at, user_id, label, rate_limit, budget_usd, budget_period
        FROM   auth_token
        WHERE  gateway_id = ? AND token_hash = ?
        LIMIT 1
    ]], gateway_id, token_hash)
    release(db)
    return row, e
end

function M.get_routing_rules(gateway_id)
    local db, err = get_conn()
    if not db then return {}, err end
    local rows = query_all(db, [[
        SELECT id, priority, conditions, actions FROM routing_rule
        WHERE  gateway_id = ? AND enabled = 1
        ORDER  BY priority DESC
    ]], gateway_id)
    release(db)
    return rows
end

function M.get_model_pricing(provider, model)
    local db, err = get_conn()
    if not db then return nil, err end
    local row, e = query_one(db, [[
        SELECT input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k
        FROM   model_price
        WHERE  provider = ? AND model = ?
    ]], provider, model)
    release(db)
    return row, e
end

-- ---------------------------------------------------------------------------
-- Write API
-- ---------------------------------------------------------------------------

function M.insert_log(f)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status, cached,
             input_tokens, output_tokens, cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, cache_deletion_tokens,
             cost_usd, latency_ms, ts,
             prompt, response, meta, blocked, blocked_by, block_reason,
             guardrail_latency_ms, guardrail_verdict,
             saved_cost_usd, saved_latency_ms,
             upstream_latency_ms, time_to_first_token_ms, upstream_attempts,
             fallback_provider, fallback_model, provider_request_id,
             request_size_bytes, quota_remaining, user_id, token_label,
             detectors_fired, scrub_applied, response_raw, prompt_scrubbed,
             token_quota_remaining, tenant_quota_remaining, trace_id,
             compaction_tokens_saved, compaction_cost_saved,
             compaction_triggered, compaction_tokens_before,
             rate_limited)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ]],
        f.id, f.tenant_id, f.gateway_id, f.provider, f.model,
        f.status, f.cached and 1 or 0,
        f.input_tokens, f.output_tokens,
        f.cache_creation_tokens or 0, f.cache_creation_1h_tokens or 0, f.cache_read_tokens or 0, f.cache_deletion_tokens or 0,
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
        f.trace_id,
        f.compaction_tokens_saved or 0,
        f.compaction_cost_saved   or 0,
        f.compaction_triggered    and 1 or 0,
        f.compaction_tokens_before or 0,
        f.rate_limited and 1 or 0
    )
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Tenant write helpers
-- ---------------------------------------------------------------------------

function M.upsert_tenant(slug, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config)
    local id = uuid()
    local db, err = get_conn()
    if not db then return nil, err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO tenant (id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config)
        VALUES (?,?,?,?,?,?,?,?)
    ]], id, slug, plan or "free", budget_usd, budget_period or "monthly", siem_config, chat_presets_config, slash_commands_config)
    if e then
        release(db)
        return nil, e
    end
    local row = query_one(db, "SELECT id FROM tenant WHERE slug = ?", slug)
    release(db)
    return row and row.id
end

function M.update_tenant(id, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE tenant SET plan = COALESCE(?, plan), budget_usd = ?,
               budget_period = COALESCE(?, budget_period),
               siem_config = COALESCE(?, siem_config),
               chat_presets_config = COALESCE(?, chat_presets_config),
               slash_commands_config = COALESCE(?, slash_commands_config)
        WHERE id = ?
    ]], plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config, id)
    release(db)
    return e
end

function M.delete_tenant(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE tenant SET deleted_at = ? WHERE id = ?", os.time(), id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Gateway write helpers
-- ---------------------------------------------------------------------------

function M.upsert_gateway(tenant_id, slug, config_table)
    local id = uuid()
    local db, err = get_conn()
    if not db then return nil, err end
    local e = exec_one(db, [[
        INSERT INTO gateway (id, tenant_id, slug, config) VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE config = VALUES(config)
    ]], id, tenant_id, slug, json.encode(config_table or {}))
    if e then
        release(db)
        return nil, e
    end
    local row = query_one(db, [[
        SELECT id FROM gateway WHERE tenant_id = ? AND slug = ?
    ]], tenant_id, slug)
    release(db)
    return row and row.id
end

function M.delete_gateway(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM gateway WHERE id = ?", id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Provider config write helpers
-- ---------------------------------------------------------------------------

function M.upsert_provider_config(gateway_id, provider, alias, encrypted_key, nonce)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO provider_config (id, gateway_id, provider, alias, encrypted_key, nonce)
        VALUES (?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            encrypted_key = VALUES(encrypted_key),
            nonce         = VALUES(nonce)
    ]], uuid(), gateway_id, provider, alias, encrypted_key, nonce)
    release(db)
    return e
end

function M.delete_provider_config(gateway_id, provider, alias)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM provider_config WHERE gateway_id = ? AND provider = ? AND alias = ?
    ]], gateway_id, provider, alias)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Auth token write helpers
-- ---------------------------------------------------------------------------

function M.insert_auth_token(gateway_id, token_hash, scopes, expires_at, user_id, label, rate_limit_json, budget_usd)
    local id = uuid()
    local db, err = get_conn()
    if not db then return nil, err end
    local e = exec_one(db, [[
        INSERT INTO auth_token (id, gateway_id, token_hash, scopes, expires_at, user_id, label, rate_limit, budget_usd)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], id, gateway_id, token_hash, json.encode(scopes or {}), expires_at, user_id, label, rate_limit_json, budget_usd)
    release(db)
    if e then return nil, e end
    return id
end

function M.delete_auth_token(token_id, gateway_id)
    local db, err = get_conn()
    if not db then return err end
    local e
    if gateway_id then
        e = exec_one(db, "DELETE FROM auth_token WHERE id = ? AND gateway_id = ?",
                     token_id, gateway_id)
    else
        e = exec_one(db, "DELETE FROM auth_token WHERE id = ?", token_id)
    end
    release(db)
    return e
end

function M.delete_playground_tokens(gateway_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db,
        "DELETE FROM auth_token WHERE gateway_id = ? AND label = 'playground'",
        gateway_id)
    release(db)
    return e
end

function M.delete_expired_playground_tokens(gateway_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM auth_token
        WHERE  gateway_id = ? AND label = 'playground'
          AND  expires_at IS NOT NULL AND expires_at <= ?
    ]], gateway_id, os.time())
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- User write helpers
-- ---------------------------------------------------------------------------

function M.insert_user(tenant_id, email, name, role)
    local id = uuid()
    local db, err = get_conn()
    if not db then return nil, err end
    local existing = query_one(db, "SELECT id FROM `user` WHERE email = ? AND deleted_at IS NULL LIMIT 1", email)
    if existing then release(db); return nil, "email already in use" end
    local e = exec_one(db, [[
        INSERT INTO `user` (id, tenant_id, email, name, role)
        VALUES (?,?,?,?,?)
    ]], id, tenant_id, email, name, role or "member")
    release(db)
    if e then return nil, e end
    return id
end

function M.update_user(id, email, name, role, tenant_id)
    local db, err = get_conn()
    if not db then return err end
    local e
    if tenant_id ~= nil then
        e = exec_one(db, [[
            UPDATE `user` SET email = ?, name = ?, role = ?, tenant_id = ? WHERE id = ?
        ]], email, name, role, tenant_id, id)
    else
        e = exec_one(db, [[
            UPDATE `user` SET email = ?, name = ?, role = ? WHERE id = ?
        ]], email, name, role, id)
    end
    release(db)
    return e
end

function M.delete_user(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE `user` SET deleted_at = ? WHERE id = ?", os.time(), id)
    release(db)
    return e
end

function M.set_user_gateway_access(user_id, gateway_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO user_gateway_access (user_id, gateway_id) VALUES (?,?)
    ]], user_id, gateway_id)
    release(db)
    return e
end

function M.delete_user_gateway_access(user_id, gateway_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM user_gateway_access WHERE user_id = ? AND gateway_id = ?
    ]], user_id, gateway_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Routing rule write helpers
-- ---------------------------------------------------------------------------

function M.upsert_routing_rule(gateway_id, id, priority, conditions, actions, enabled)
    local db, err = get_conn()
    if not db then return err end
    if id and id ~= "" then
        local e = exec_one(db, [[
            UPDATE routing_rule SET priority=?, conditions=?, actions=?, enabled=?
            WHERE id=? AND gateway_id=?
        ]], priority, json.encode(conditions or {}), json.encode(actions or {}),
            enabled and 1 or 0, id, gateway_id)
        release(db)
        return e
    end
    local new_id = uuid()
    exec_one(db, [[
        INSERT INTO routing_rule (id, gateway_id, priority, conditions, actions, enabled)
        VALUES (?,?,?,?,?,?)
    ]], new_id, gateway_id, priority or 0,
        json.encode(conditions or {}), json.encode(actions or {}),
        enabled ~= false and 1 or 0)
    release(db)
    return new_id
end

function M.delete_routing_rule(rule_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM routing_rule WHERE id = ?", rule_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Model pricing write helpers
-- ---------------------------------------------------------------------------

function M.upsert_model_price(provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO model_price
            (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k, updated_at)
        VALUES (?,?,?,?,?,?,?,UNIX_TIMESTAMP())
        ON DUPLICATE KEY UPDATE
            input_per_1k          = VALUES(input_per_1k),
            output_per_1k         = VALUES(output_per_1k),
            cache_write_per_1k    = VALUES(cache_write_per_1k),
            cache_read_per_1k     = VALUES(cache_read_per_1k),
            cache_write_1h_per_1k = VALUES(cache_write_1h_per_1k),
            updated_at            = UNIX_TIMESTAMP()
    ]], provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k)
    release(db)
    return e
end

function M.delete_model_price(provider, model)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM model_price WHERE provider=? AND model=?", provider, model)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Spend ledger
-- ---------------------------------------------------------------------------

function M.incr_spend(entity_type, entity_id, period, micro)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO spend_ledger (entity_type, entity_id, period, amount_micro, updated_at)
        VALUES (?, ?, ?, ?, UNIX_TIMESTAMP())
        ON DUPLICATE KEY UPDATE
            amount_micro = amount_micro + VALUES(amount_micro),
            updated_at   = UNIX_TIMESTAMP()
    ]], entity_type, entity_id, period, micro)
    release(db)
    return e
end

function M.get_spend(entity_type, entity_id, period)
    local db, err = get_conn()
    if not db then return 0 end
    local row = query_one(db, [[
        SELECT amount_micro FROM spend_ledger
        WHERE entity_type = ? AND entity_id = ? AND period = ?
    ]], entity_type, entity_id, period)
    release(db)
    return row and tonumber(row.amount_micro) or 0
end

function M.get_spend_history(entity_type, entity_id, limit)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT period, amount_micro, updated_at
        FROM spend_ledger
        WHERE entity_type = ? AND entity_id = ?
        ORDER BY period DESC
        LIMIT %d
    ]], limit or 12), entity_type, entity_id)
    release(db)
    return rows or {}
end

function M.reset_spend(entity_type, entity_id, period)
    local db, err = get_conn()
    if not db then return err end
    local e
    if period then
        e = exec_one(db, [[
            DELETE FROM spend_ledger WHERE entity_type = ? AND entity_id = ? AND period = ?
        ]], entity_type, entity_id, period)
    else
        e = exec_one(db, [[
            DELETE FROM spend_ledger WHERE entity_type = ? AND entity_id = ?
        ]], entity_type, entity_id)
    end
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Admin list / read queries
-- ---------------------------------------------------------------------------

function M.get_tenant(id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config,
               created_at
        FROM tenant WHERE id = ? AND deleted_at IS NULL
    ]], id)
    release(db)
    return row
end

function M.list_tenants(tenant_id_filter)
    local db, err = get_conn()
    if not db then return {} end
    local rows
    if tenant_id_filter then
        rows = query_all(db, [[
            SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config,
                   created_at
            FROM tenant WHERE deleted_at IS NULL AND id = ?
            ORDER BY created_at DESC
        ]], tenant_id_filter) or {}
    else
        rows = query_all(db, [[
            SELECT id, slug, plan, budget_usd, budget_period, siem_config, chat_presets_config, slash_commands_config,
                   created_at
            FROM tenant WHERE deleted_at IS NULL ORDER BY created_at DESC
        ]]) or {}
    end
    release(db)
    return rows
end

function M.list_gateways(tenant_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT g.id, g.slug, g.tenant_id, g.config,
               g.created_at
        FROM gateway g WHERE g.tenant_id = ? ORDER BY g.created_at DESC
    ]], tenant_id) or {}
    release(db)
    return rows
end

function M.list_gateways_all()
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, slug, tenant_id, config FROM gateway ORDER BY created_at DESC LIMIT 200
    ]]) or {}
    release(db)
    return rows
end

function M.get_gateway_by_id(gateway_id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT g.id, g.slug, g.config, g.tenant_id,
               g.created_at
        FROM gateway g WHERE g.id = ?
    ]], gateway_id)
    release(db)
    return row
end

function M.get_gateway_with_tenant_slug(gateway_id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT g.id, g.slug AS gateway_slug, g.tenant_id,
               t.slug AS tenant_slug
        FROM   gateway g
        JOIN   tenant  t ON t.id = g.tenant_id
        WHERE  g.id = ? AND t.deleted_at IS NULL
    ]], gateway_id)
    release(db)
    return row
end

function M.list_auth_tokens(gateway_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, token_hash, scopes, user_id, label, rate_limit, budget_usd,
               CASE WHEN expires_at IS NOT NULL
                    THEN expires_at END AS expires_at,
               created_at
        FROM auth_token WHERE gateway_id = ?
          AND (expires_at IS NULL OR expires_at > ?)
        ORDER BY created_at DESC
    ]], gateway_id, os.time()) or {}
    release(db)
    return rows
end

function M.list_provider_configs(gateway_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, provider, alias,
               created_at
        FROM provider_config WHERE gateway_id = ? ORDER BY provider, alias
    ]], gateway_id) or {}
    release(db)
    return rows
end

function M.get_first_provider_key(provider)
    local db, err = get_conn()
    if not db then return nil, nil, nil, err end
    local row, e = query_one(db, [[
        SELECT gateway_id, encrypted_key, nonce
        FROM provider_config WHERE provider = ? LIMIT 1
    ]], provider)
    release(db)
    if not row then return nil, nil, nil, e end
    return row.gateway_id, row.encrypted_key, row.nonce
end

-- ---------------------------------------------------------------------------
-- Tenant-scoped provider key helpers (provider_config rows with tenant_id,
-- no gateway_id — used for management keys like anthropic-admin).
-- ---------------------------------------------------------------------------

function M.get_tenant_provider_key(tenant_id, provider, alias)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return nil, nil, err end
    local row, e = query_one(db, [[
        SELECT encrypted_key, nonce FROM provider_config
        WHERE  tenant_id = ? AND provider = ? AND alias = ? AND gateway_id IS NULL
        LIMIT 1
    ]], tenant_id, provider, alias)
    release(db)
    if e then return nil, nil, e end
    if not row then return nil, nil, "not_found" end
    return row.encrypted_key, row.nonce
end

function M.upsert_tenant_provider_config(tenant_id, provider, alias, encrypted_key, nonce)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO provider_config (id, tenant_id, provider, alias, encrypted_key, nonce)
        VALUES (?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            encrypted_key = VALUES(encrypted_key),
            nonce         = VALUES(nonce)
    ]], uuid(), tenant_id, provider, alias, encrypted_key, nonce)
    release(db)
    return e
end

function M.delete_tenant_provider_config(tenant_id, provider, alias)
    alias = alias or "default"
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM provider_config
        WHERE tenant_id = ? AND provider = ? AND alias = ? AND gateway_id IS NULL
    ]], tenant_id, provider, alias)
    release(db)
    return e
end

function M.list_tenant_provider_configs(tenant_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, provider, alias, created_at
        FROM provider_config
        WHERE tenant_id = ? AND gateway_id IS NULL
        ORDER BY provider, alias
    ]], tenant_id) or {}
    release(db)
    return rows
end

-- Returns all tenants that have an anthropic-admin key configured.
-- Used by the usage sync to know who to fetch data for.
function M.list_tenants_with_anthropic_admin_key()
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT t.id AS tenant_id, t.slug, pc.encrypted_key, pc.nonce
        FROM   provider_config pc
        JOIN   tenant t ON t.id = pc.tenant_id
        WHERE  pc.provider = 'anthropic-admin'
          AND  pc.gateway_id IS NULL
          AND  t.deleted_at IS NULL
    ]]) or {}
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- Anthropic usage snapshot helpers
-- ---------------------------------------------------------------------------

function M.upsert_anthropic_usage(row)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO anthropic_usage_snapshot
            (id, tenant_id, snapshot_date, source, model, service_tier,
             uncached_input_tokens, output_tokens,
             cache_write_5m_tokens, cache_write_1h_tokens, cache_read_tokens,
             web_search_requests, cost_usd)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            uncached_input_tokens = VALUES(uncached_input_tokens),
            output_tokens         = VALUES(output_tokens),
            cache_write_5m_tokens = VALUES(cache_write_5m_tokens),
            cache_write_1h_tokens = VALUES(cache_write_1h_tokens),
            cache_read_tokens     = VALUES(cache_read_tokens),
            web_search_requests   = VALUES(web_search_requests),
            cost_usd              = VALUES(cost_usd)
    ]], uuid(), row.tenant_id, row.snapshot_date, row.source, row.model,
        row.service_tier, row.uncached_input_tokens, row.output_tokens,
        row.cache_write_5m_tokens, row.cache_write_1h_tokens, row.cache_read_tokens,
        row.web_search_requests, row.cost_usd)
    release(db)
    return e
end

function M.get_anthropic_usage(tenant_id, from_date, to_date)
    local db, err = get_conn()
    if not db then return {}, err end
    local rows = query_all(db, [[
        SELECT snapshot_date, source, model, service_tier,
               SUM(uncached_input_tokens)  AS uncached_input_tokens,
               SUM(output_tokens)          AS output_tokens,
               SUM(cache_write_5m_tokens)  AS cache_write_5m_tokens,
               SUM(cache_write_1h_tokens)  AS cache_write_1h_tokens,
               SUM(cache_read_tokens)      AS cache_read_tokens,
               SUM(web_search_requests)    AS web_search_requests,
               CAST(SUM(cost_usd) AS CHAR) AS cost_usd,
               MAX(UNIX_TIMESTAMP(fetched_at)) AS fetched_at
        FROM   anthropic_usage_snapshot
        WHERE  tenant_id = ?
          AND  snapshot_date >= ? AND snapshot_date <= ?
        GROUP  BY snapshot_date, source, model, service_tier
        ORDER  BY snapshot_date DESC, model
    ]], tenant_id, from_date, to_date) or {}
    release(db)
    return rows
end

function M.list_routing_rules(gateway_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, priority, conditions, actions, enabled FROM routing_rule
        WHERE gateway_id = ? ORDER BY priority DESC
    ]], gateway_id) or {}
    release(db)
    return rows
end

function M.get_user(id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT id, tenant_id, email, name, role,
               CASE WHEN deleted_at IS NOT NULL
                    THEN deleted_at END AS deleted_at,
               created_at,
               CASE WHEN last_login_at IS NOT NULL
                    THEN last_login_at END AS last_login_at
        FROM `user` WHERE id = ?
    ]], id)
    release(db)
    return row
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
    local db, err = get_conn()
    if not db then return {} end
    opts = opts or {}
    local col = USER_SORT_COLS[opts.sort] or "u.email"
    local dir = (opts.dir == "desc") and "DESC" or "ASC"
    assert(dir == "ASC" or dir == "DESC", "invalid sort direction")
    local order = col .. " " .. dir
    local rows
    if tenant_id then
        rows = query_all(db, string.format([[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   t.slug AS tenant_slug,
                   u.created_at,
                   CASE WHEN u.last_login_at IS NOT NULL
                        THEN u.last_login_at END AS last_login_at
            FROM `user` u
            LEFT JOIN tenant t ON t.id = u.tenant_id
            WHERE u.tenant_id = ? AND u.deleted_at IS NULL
            ORDER BY %s
        ]], order), tenant_id) or {}
    elseif tenant_id == false then
        rows = query_all(db, string.format([[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   NULL AS tenant_slug,
                   u.created_at,
                   CASE WHEN u.last_login_at IS NOT NULL
                        THEN u.last_login_at END AS last_login_at
            FROM `user` u
            WHERE u.tenant_id IS NULL AND u.deleted_at IS NULL
            ORDER BY %s
        ]], order)) or {}
    else
        rows = query_all(db, string.format([[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   t.slug AS tenant_slug,
                   u.created_at,
                   CASE WHEN u.last_login_at IS NOT NULL
                        THEN u.last_login_at END AS last_login_at
            FROM `user` u
            LEFT JOIN tenant t ON t.id = u.tenant_id
            WHERE u.deleted_at IS NULL
            ORDER BY %s
        ]], order)) or {}
    end
    release(db)
    return rows
end

function M.search_users_by_email(tenant_id, email)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, email, name
        FROM `user`
        WHERE tenant_id = ? AND email = ? AND deleted_at IS NULL
        LIMIT 5
    ]], tenant_id, email)
    release(db)
    return rows or {}
end

function M.touch_last_login(user_id)
    local db, err = get_conn()
    if not db then return end
    exec_one(db, "UPDATE `user` SET last_login_at = UNIX_TIMESTAMP() WHERE id = ?", user_id)
    release(db)
end

function M.list_user_gateways(user_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT g.id, g.slug, g.tenant_id
        FROM gateway g
        JOIN user_gateway_access a ON a.gateway_id = g.id
        WHERE a.user_id = ?
        ORDER BY g.slug
    ]], user_id) or {}
    release(db)
    return rows
end

function M.check_user_gateway_access(user_id, gateway_id)
    local db, err = get_conn()
    if not db then return false end
    local row = query_one(db, [[
        SELECT 1 FROM user_gateway_access WHERE user_id = ? AND gateway_id = ?
    ]], user_id, gateway_id)
    release(db)
    return row ~= nil
end

function M.list_user_tokens(user_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, gateway_id, token_hash, scopes, label, rate_limit, budget_usd,
               CASE WHEN expires_at IS NOT NULL
                    THEN expires_at END AS expires_at,
               created_at
        FROM auth_token WHERE user_id = ? ORDER BY created_at DESC
    ]], user_id) or {}
    release(db)
    return rows
end

function M.list_model_prices()
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT provider, model, input_per_1k, output_per_1k,
               cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k,
               updated_at
        FROM model_price ORDER BY provider, model
    ]]) or {}
    release(db)
    return rows
end

function M.list_models(provider)
    if provider and provider ~= "" then
        local db, err = get_conn()
        if not db then return {} end
        local rows = query_all(db, [[
            SELECT provider, model, input_per_1k, output_per_1k,
                   cache_write_per_1k, cache_read_per_1k, cache_write_1h_per_1k,
                   updated_at
            FROM   model_price
            WHERE  provider = ?
            ORDER  BY model
        ]], provider) or {}
        release(db)
        return rows
    end
    return M.list_model_prices()
end

-- ---------------------------------------------------------------------------
-- Log list / read
-- ---------------------------------------------------------------------------

function M.list_logs(filters)
    filters = filters or {}
    local where  = {"1=1"}
    local params = {}
    if filters.tenant_id  then where[#where+1] = "tenant_id = ?";  params[#params+1] = filters.tenant_id  end
    if filters.gateway_id then where[#where+1] = "gateway_id = ?"; params[#params+1] = filters.gateway_id end
    if filters.provider   then where[#where+1] = "provider = ?";   params[#params+1] = filters.provider   end
    if filters.model      then where[#where+1] = "model = ?";      params[#params+1] = filters.model      end
    if filters.status     then where[#where+1] = "status = ?";     params[#params+1] = tonumber(filters.status) end
    if filters.blocked == "1" or filters.blocked == true then
        where[#where+1] = "blocked = 1"
    end
    if filters.since then
        where[#where+1] = "ts >= ?"
        params[#params+1] = filters.since
    end
    if filters.guardrail_outcome then
        local o = filters.guardrail_outcome
        if     o == "blocked"  then where[#where+1] = "blocked = 1"
        elseif o == "scrubbed" then where[#where+1] = "scrub_applied = 1 AND blocked = 0"
        elseif o == "flagged"  then where[#where+1] = "detectors_fired IS NOT NULL AND detectors_fired != '[]' AND blocked = 0 AND scrub_applied = 0"
        elseif o == "any"      then where[#where+1] = "(blocked = 1 OR scrub_applied = 1 OR (detectors_fired IS NOT NULL AND detectors_fired != '[]'))"
        end
    end
    local limit  = math.min(filters.limit or 50, 200)
    local offset = filters.offset or 0
    local sql = string.format([[
        SELECT id,
               ROUND(ts / 1000) AS ts,
               tenant_id, gateway_id,
               provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cache_deletion_tokens,
               cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes,
               detectors_fired, scrub_applied, prompt, response_raw, trace_id,
               rate_limited
        FROM request_log WHERE %s ORDER BY ts DESC LIMIT %d OFFSET %d
    ]], table.concat(where, " AND "), limit, offset)

    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, sql, table.unpack(params)) or {}
    release(db)
    for _, row in ipairs(rows) do decode_detectors(row) end
    return rows
end

function M.get_log(id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT id,
               ROUND(ts / 1000) AS ts,
               tenant_id, gateway_id, provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, cache_deletion_tokens, cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes,
               detectors_fired, scrub_applied,
               prompt, response, response_raw, prompt_scrubbed
        FROM request_log WHERE id = ?
    ]], id)
    release(db)
    if not row then return nil end
    decode_detectors(row)
    return row
end

-- ---------------------------------------------------------------------------
-- Usage stats (dashboard overview)
-- ---------------------------------------------------------------------------

function M.get_usage_stats(tenant_id, user_id)
    local db, err = get_conn()
    if not db then return {} end

    local now          = math.floor(ngx.now())
    local today_ms     = (now - (now % 86400)) * 1000
    local yesterday_ms = today_ms - 86400 * 1000
    local last_7d_ms   = today_ms - 7 * 86400 * 1000
    local hour_ms      = (now - 3600) * 1000
    local last_min_ms  = (now - 60) * 1000

    local tenant_clause = ""
    local tenant_param  = nil
    if tenant_id and tenant_id ~= "" then
        assert(tenant_id:match("^[0-9a-fA-F%-]+$"), "tenant_id must be UUID format")
        tenant_clause = " AND tenant_id = ?"
        tenant_param  = tenant_id
    end

    local user_clause = ""
    local user_param  = nil
    if user_id and user_id ~= "" then
        assert(user_id:match("^[0-9a-fA-F%-]+$"), "user_id must be UUID format")
        user_clause = " AND user_id = ?"
        user_param  = user_id
    end
    local extra_clause = tenant_clause .. user_clause

    local function bind_params(...)
        local t = {}
        if tenant_param then t[#t+1] = tenant_param end
        if user_param   then t[#t+1] = user_param   end
        for _, v in ipairs({...}) do t[#t+1] = v end
        return table.unpack(t)
    end

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
            ROUND(COALESCE(AVG(CASE WHEN %s THEN upstream_latency_ms END),0)) AS %s_avg_up,
            SUM(CASE WHEN %s AND rate_limited=1 THEN 1 ELSE 0 END) AS %s_rate_limited]],
            cond,p, cond,p, cond,p, cond,p, cond,p,
            cond,p, cond,p, cond,p, cond,p, cond,p, cond,p, cond,p)
    end

    local all_sql = string.format(
        "SELECT %s, %s, %s, %s, %s FROM request_log WHERE ts >= %d%s",
        pcols("lm", "ts >= " .. last_min_ms),
        pcols("hr", "ts >= " .. hour_ms),
        pcols("td", "ts >= " .. today_ms),
        pcols("yd", string.format("ts >= %d AND ts < %d", yesterday_ms, today_ms)),
        pcols("l7", "1=1"),
        last_7d_ms, extra_clause)

    local r = query_one(db, all_sql, bind_params()) or {}

    local function extract(p)
        return {
            requests                = r[p.."_req"]          or 0,
            cached                  = r[p.."_cached"]       or 0,
            blocked                 = r[p.."_blocked"]      or 0,
            scrubbed                = r[p.."_scrubbed"]     or 0,
            flagged                 = r[p.."_flagged"]      or 0,
            input_tokens            = r[p.."_in_tok"]       or 0,
            output_tokens           = r[p.."_out_tok"]      or 0,
            cost_usd                = r[p.."_cost"]         or 0,
            saved_cost_usd          = r[p.."_saved"]        or 0,
            avg_latency_ms          = r[p.."_avg_lat"]      or 0,
            avg_upstream_latency_ms = r[p.."_avg_up"]       or 0,
            rate_limited            = r[p.."_rate_limited"] or 0,
        }
    end

    local by_tenant = {}
    if not user_id then
        local by_tenant_sql = string.format([[
            SELECT r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
                   COUNT(*) AS requests,
                   COALESCE(SUM(r.input_tokens),0)  AS input_tokens,
                   COALESCE(SUM(r.output_tokens),0) AS output_tokens,
                   ROUND(COALESCE(SUM(r.cost_usd),0),4) AS cost_usd
            FROM request_log r
            LEFT JOIN tenant t ON t.id = r.tenant_id
            WHERE r.ts >= %d AND t.id IS NOT NULL AND t.deleted_at IS NULL%s
            GROUP BY r.tenant_id ORDER BY cost_usd DESC
        ]], today_ms, tenant_clause)
        by_tenant = query_all(db, by_tenant_sql, table.unpack(tenant_param and {tenant_param} or {})) or {}
    end

    local recent_sql = string.format([[
        SELECT ROUND(r.ts / 1000) AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.gateway_id, COALESCE(g.slug, r.gateway_id) AS gateway,
               r.provider, r.model,
               r.status, r.input_tokens, r.output_tokens,
               ROUND(r.cost_usd,5) AS cost_usd, r.latency_ms, r.cached,
               r.blocked, r.blocked_by, r.block_reason,
               r.guardrail_verdict, r.guardrail_latency_ms,
               r.upstream_latency_ms, r.upstream_attempts,
               r.fallback_provider, r.fallback_model,
               ROUND(r.saved_cost_usd,5) AS saved_cost_usd, r.request_size_bytes,
               r.rate_limited
        FROM request_log r
        LEFT JOIN tenant t ON t.id = r.tenant_id
        LEFT JOIN gateway g ON g.id = r.gateway_id
        WHERE t.id IS NOT NULL AND t.deleted_at IS NULL%s
        ORDER BY r.ts DESC LIMIT 10
    ]], extra_clause)
    local recent = query_all(db, recent_sql, bind_params()) or {}

    local recent_blocked_sql = string.format([[
        SELECT ROUND(r.ts / 1000) AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.gateway_id, COALESCE(g.slug, r.gateway_id) AS gateway,
               r.blocked_by, r.block_reason, r.latency_ms,
               r.guardrail_latency_ms, r.guardrail_verdict,
               r.blocked, r.scrub_applied, r.detectors_fired,
               r.response_raw, r.prompt_scrubbed
        FROM request_log r
        LEFT JOIN tenant t ON t.id = r.tenant_id
        LEFT JOIN gateway g ON g.id = r.gateway_id
        WHERE t.id IS NOT NULL AND t.deleted_at IS NULL
          AND (r.blocked = 1
           OR r.scrub_applied = 1
           OR (r.detectors_fired IS NOT NULL AND r.detectors_fired != '[]'))%s
        ORDER BY r.ts DESC LIMIT 20
    ]], extra_clause)
    local recent_blocked = query_all(db, recent_blocked_sql, bind_params()) or {}
    for _, row in ipairs(recent_blocked) do decode_detectors(row) end

    release(db)
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

function M.get_stats_timeseries(bucket_sec, n, end_sec, tenant_id, user_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end

    local ref            = end_sec or math.floor(ngx.now())
    local bms            = bucket_sec * 1000
    local now_bucket_sec = math.floor(ref / bucket_sec) * bucket_sec
    local since_ms       = (now_bucket_sec - (n - 1) * bucket_sec) * 1000

    local tenant_clause = ""
    if tenant_id then
        tenant_clause = " AND tenant_id = ?"
    end
    local user_clause = ""
    if user_id then
        user_clause = " AND user_id = ?"
    end
    local sql = string.format([[
        SELECT (ts DIV %d) * %d AS bucket_ts,
               COUNT(*) AS requests,
               SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
               SUM(CASE WHEN rate_limited=1 THEN 1 ELSE 0 END) AS rate_limited,
               ROUND(COALESCE(SUM(cost_usd),0),6) AS cost_usd
        FROM request_log
        WHERE ts >= ?%s%s
        GROUP BY bucket_ts
        ORDER BY bucket_ts ASC
    ]], bms, bms, tenant_clause, user_clause)

    local params = { since_ms }
    if tenant_id then params[#params+1] = tenant_id end
    if user_id   then params[#params+1] = user_id   end
    local rows = query_all(db, sql, table.unpack(params)) or {}
    release(db)

    local by_ts = {}
    for _, r in ipairs(rows) do by_ts[r.bucket_ts] = r end

    local result = setmetatable({}, cjson.array_mt)
    for i = 0, n - 1 do
        local bts = (now_bucket_sec - (n - 1 - i) * bucket_sec) * 1000
        local r   = by_ts[bts] or {}
        result[#result + 1] = {
            ts           = bts,
            requests     = r.requests     or 0,
            blocked      = r.blocked      or 0,
            rate_limited = r.rate_limited or 0,
            cost_usd     = r.cost_usd     or 0,
        }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Analytics depth: latency percentiles + top models (requires MySQL 8.0+)
-- ---------------------------------------------------------------------------

-- until_ms is optional; when set, queries use ts >= from AND ts < until_ms
-- (closed window — used for "yesterday" so today's data is excluded).
function M.get_analytics_depth(since_ms, tenant_id, until_ms)
    local db, err = get_conn()
    if not db then return {} end

    local now_ms = math.floor(ngx.now() * 1000)
    local from   = since_ms or (now_ms - 86400 * 1000)

    -- Upper-bound clause: only set for closed windows (e.g. yesterday).
    local uc = ""
    if until_ms then
        uc = string.format(" AND r.ts < %d", math.floor(until_ms))
    end

    local tc          = ""
    local tc_param    = nil
    if tenant_id and tenant_id ~= "" then
        assert(tenant_id:match("^[0-9a-fA-F%-]+$"), "tenant_id must be UUID format")
        tc       = " AND r.tenant_id = ?"
        tc_param = tenant_id
    end

    -- Base bind params: `from` always; `tc_param` added when tenant filter is active.
    local bind_params = tc_param and {from, tc_param} or {from}

    -- Window functions: ROW_NUMBER() and COUNT(*) OVER () — MySQL 8.0+
    local pct = query_one(db, string.format([[
        SELECT
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.50) AS UNSIGNED) THEN latency_ms END) AS p50,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.95) AS UNSIGNED) THEN latency_ms END) AS p95,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.99) AS UNSIGNED) THEN latency_ms END) AS p99
        FROM (
            SELECT latency_ms,
                   ROW_NUMBER() OVER (ORDER BY latency_ms) AS rn,
                   COUNT(*)     OVER ()                    AS cnt
            FROM request_log r
            WHERE r.ts >= ? AND r.latency_ms IS NOT NULL AND r.blocked = 0%s%s
        ) sub
    ]], tc, uc), table.unpack(bind_params)) or {}

    local top_models = query_all(db, string.format([[
        SELECT r.model, r.provider,
               COUNT(*) AS requests,
               ROUND(COALESCE(SUM(r.cost_usd),0),4) AS cost_usd,
               ROUND(COALESCE(AVG(r.latency_ms),0))  AS avg_latency_ms
        FROM request_log r
        WHERE r.ts >= ?%s%s
        GROUP BY r.provider, r.model
        ORDER BY requests DESC
        LIMIT 10
    ]], tc, uc), table.unpack(bind_params)) or {}

    local by_tenant = query_all(db, string.format([[
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
        LEFT JOIN tenant t ON t.id = r.tenant_id
        WHERE r.ts >= ?%s%s AND t.id IS NOT NULL AND t.deleted_at IS NULL
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], tc, uc), table.unpack(bind_params)) or {}

    local by_gateway = query_all(db, string.format([[
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
        LEFT JOIN gateway g ON g.id = r.gateway_id
        LEFT JOIN tenant  t ON t.id = r.tenant_id
        WHERE r.ts >= ?%s%s AND t.id IS NOT NULL AND t.deleted_at IS NULL
        GROUP BY r.gateway_id ORDER BY cost_usd DESC
    ]], tc, uc), table.unpack(bind_params)) or {}

    local by_user = query_all(db, string.format([[
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
        LEFT JOIN `user` u ON u.id = r.user_id
        WHERE r.ts >= ? AND r.user_id IS NOT NULL%s%s
        GROUP BY r.user_id, r.tenant_id ORDER BY cost_usd DESC
        LIMIT 50
    ]], tc, uc), table.unpack(bind_params)) or {}

    -- Anthropic prompt-cache efficiency.
    -- "Uncached" = cache_creation_tokens + input_tokens (processed fresh, not served from cache).
    -- "Cached"   = cache_read_tokens only (served cheaply from Anthropic's cache).
    -- Joins model_price per row for accurate per-model pricing.
    local cache_eff = query_one(db, string.format([[
        SELECT
            COALESCE(SUM(r.cache_creation_tokens + r.cache_creation_1h_tokens), 0) AS cache_write_tokens,
            COALESCE(SUM(r.cache_read_tokens),     0) AS cache_read_tokens,
            COALESCE(SUM(r.input_tokens),          0) AS standard_input_tokens,
            ROUND(SUM(
                r.cache_creation_tokens     * COALESCE(mp.cache_write_per_1k,    0) / 1000 +
                r.cache_creation_1h_tokens  * COALESCE(mp.cache_write_1h_per_1k, mp.cache_write_per_1k * 1.6, 0) / 1000 +
                r.input_tokens              * COALESCE(mp.input_per_1k,          0) / 1000
            ), 4) AS uncached_cost_usd,
            ROUND(SUM(
                r.cache_read_tokens * COALESCE(mp.cache_read_per_1k, 0) / 1000
            ), 4) AS cached_cost_usd,
            ROUND(
                COALESCE(SUM(r.cache_read_tokens), 0) * 100.0 /
                NULLIF(SUM(r.cache_creation_tokens + r.cache_creation_1h_tokens + r.cache_read_tokens + r.input_tokens), 0),
            1) AS cache_hit_pct,
            COALESCE(SUM(r.compaction_tokens_saved), 0) AS compaction_tokens_saved,
            ROUND(COALESCE(SUM(r.compaction_cost_saved), 0), 4) AS compaction_cost_saved
        FROM request_log r
        LEFT JOIN model_price mp ON mp.provider = r.provider AND mp.model = r.model
        WHERE r.provider = 'anthropic' AND r.status = 200 AND r.ts >= ?%s%s
    ]], tc, uc), table.unpack(bind_params)) or {}

    release(db)
    return {
        percentiles     = pct,
        top_models      = top_models,
        by_tenant       = by_tenant,
        by_gateway      = by_gateway,
        by_user         = by_user,
        cache_efficiency = cache_eff,
    }
end

function M.get_tenant_top_models(tenant_id, since_ms)
    local db, err = get_conn()
    if not db then return {} end
    local from = since_ms or (math.floor(ngx.now() * 1000) - 86400 * 1000)
    local rows = query_all(db, [[
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
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- Client error log
-- ---------------------------------------------------------------------------

function M.insert_client_error(id, message, stack, url, user_agent, ts)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO client_error_log (id, message, stack, url, user_agent, ts)
        VALUES (?,?,?,?,?,?)
    ]], id, message, stack, url, user_agent, ts)
    release(db)
    return e
end

function M.list_client_errors(limit)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT id, message, stack, url, user_agent,
               ROUND(ts / 1000) AS ts
        FROM   client_error_log
        ORDER  BY ts DESC
        LIMIT  %d
    ]], limit or 200)) or {}
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

function M.insert_audit_log(actor_ip, method, path, status, actor_id)
    local db = select(1, get_conn())
    if not db then return end
    pcall(exec_one, db, [[
        INSERT INTO audit_log (actor_ip, actor_id, method, path, status)
        VALUES (?, ?, ?, ?, ?)
    ]], actor_ip, actor_id, method, path, status)
    release(db)
end

function M.list_audit_logs(limit, offset)
    limit  = math.min(limit or 100, 500)
    offset = offset or 0
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT id,
               ROUND(ts / 1000) AS ts,
               actor_id, actor_ip, method, path, status
        FROM   audit_log
        ORDER  BY id DESC
        LIMIT  %d OFFSET %d
    ]], limit, offset)) or {}
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- Playground trace API
-- ---------------------------------------------------------------------------

function M.create_playground_trace(id, gateway_id, model)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO playground_trace (id, gateway_id, model, source)
        VALUES (?, ?, ?, 'playground')
    ]], id, gateway_id, model)
    release(db)
    return e
end

function M.create_trace(id, gateway_id, model, source)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO playground_trace (id, gateway_id, model, source)
        VALUES (?, ?, ?, ?)
    ]], id, gateway_id, model, source or "gateway")
    release(db)
    return e
end

function M.list_gateway_traces(gateway_id, limit)
    limit = math.min(limit or 50, 200)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT id, model, created_at, completed_at, status, error, source
        FROM   playground_trace
        WHERE  gateway_id = ? AND source = 'gateway'
        ORDER  BY created_at DESC
        LIMIT  %d
    ]], limit), gateway_id) or {}
    release(db)
    return rows
end

function M.purge_old_traces(retention_sec)
    local cutoff = os.time() - (retention_sec or 86400)
    local db = select(1, get_conn())
    if not db then return end
    exec_one(db, [[
        DELETE FROM playground_trace WHERE source = 'gateway' AND created_at < ?
    ]], cutoff)
    release(db)
end

function M.add_playground_trace_step(trace_id, seq, step, data_json)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO playground_trace_step (trace_id, seq, step, data)
        VALUES (?, ?, ?, ?)
    ]], trace_id, seq, step, data_json)
    release(db)
    return e
end

function M.complete_playground_trace(id, status, error_msg)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE playground_trace
        SET status = ?, error = ?, completed_at = ?
        WHERE id = ?
    ]], status, error_msg, os.time(), id)
    release(db)
    return e
end

function M.get_playground_trace(id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, "SELECT * FROM playground_trace WHERE id = ?", id)
    release(db)
    return row
end

function M.get_playground_trace_steps(trace_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT * FROM playground_trace_step WHERE trace_id = ? ORDER BY seq
    ]], trace_id) or {}
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- Per-gateway guardrail stats and events
-- ---------------------------------------------------------------------------

function M.get_gateway_guardrail_stats(gateway_id)
    local db, err = get_conn()
    if not db then return { blocked=0, scrubbed=0, flagged=0, avg_guardrail_ms=0 } end
    local since_ms = (math.floor(ngx.now()) - 86400) * 1000
    local stats = query_one(db, [[
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
    release(db)
    return {
        blocked          = stats.blocked          or 0,
        scrubbed         = stats.scrubbed         or 0,
        flagged          = stats.flagged          or 0,
        avg_guardrail_ms = stats.avg_guardrail_ms or 0,
    }
end

function M.list_guardrail_events(gateway_id, limit)
    limit = math.min(limit or 50, 200)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT ROUND(ts / 1000) AS ts,
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
    release(db)
    for _, row in ipairs(rows) do decode_detectors(row) end
    return rows
end

-- ---------------------------------------------------------------------------
-- Semantic cache
-- ---------------------------------------------------------------------------

function M.insert_semantic_cache(entry)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO semantic_cache
            (id, gateway_id, model, prompt_hash, embedding,
             response_body, cost_usd, created_at, expires_at, hit_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
    ]], entry.id, entry.gateway_id, entry.model, entry.prompt_hash,
        entry.embedding, entry.response_body, entry.cost_usd or 0,
        entry.created_at, entry.expires_at or 0)
    release(db)
    return e
end

function M.find_semantic_candidates(gateway_id, model, limit)
    limit = math.min(limit or 100, 500)
    local now = math.floor(ngx.now())
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT id, embedding, response_body, cost_usd
        FROM semantic_cache
        WHERE gateway_id = ? AND model = ?
          AND (expires_at = 0 OR expires_at > ?)
        ORDER BY created_at DESC
        LIMIT %d
    ]], limit), gateway_id, model, now) or {}
    release(db)
    return rows
end

function M.increment_semantic_hit(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE semantic_cache SET hit_count = hit_count + 1 WHERE id = ?
    ]], id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Admin user lookup
-- ---------------------------------------------------------------------------

function M.find_admin_user_by_email(email)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT id, email, name, role, tenant_id
        FROM `user`
        WHERE email = ? AND deleted_at IS NULL
        LIMIT 1
    ]], email)
    release(db)
    return row
end

function M.bootstrap_admin()
    local email = os.getenv("AIG_BOOTSTRAP_ADMIN_EMAIL")
    if not email or email == "" then return end
    local db, err = get_conn()
    if not db then
        ngx.log(ngx.ERR, "bootstrap_admin: cannot connect: ", err)
        return
    end
    local existing = query_one(db, [[
        SELECT id FROM `user` WHERE role = 'admin' AND deleted_at IS NULL LIMIT 1
    ]])
    if existing then release(db); return end
    local name = os.getenv("AIG_BOOTSTRAP_ADMIN_NAME") or "Admin"
    exec_one(db, [[
        INSERT IGNORE INTO `user` (id, tenant_id, email, name, role)
        VALUES (?, NULL, ?, ?, 'admin')
    ]], uuid(), email, name)
    release(db)
    ngx.log(ngx.NOTICE, "auth: bootstrap admin created — ", email,
            " — use email OTP or Google SSO to log in")
end

-- ---------------------------------------------------------------------------
-- Email OTP
-- ---------------------------------------------------------------------------

function M.insert_email_otp(id, email, code_hash, expires_at, ip_addr)
    local db, err = get_conn()
    if not db then return err end
    -- Purge stale OTPs
    pcall(exec_one, db, [[
        DELETE FROM email_otp WHERE email = ? AND (used_at IS NOT NULL OR expires_at < UNIX_TIMESTAMP())
    ]], email)
    local e = exec_one(db, [[
        INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES (?,?,?,?,?)
    ]], id, email, code_hash, expires_at, ip_addr)
    release(db)
    return e
end

function M.consume_email_otp(email, code_hash)
    local db, err = get_conn()
    if not db then return "db unavailable" end
    local row = query_one(db, [[
        SELECT id FROM email_otp
        WHERE email = ? AND code_hash = ? AND used_at IS NULL AND expires_at > UNIX_TIMESTAMP()
        LIMIT 1
    ]], email, code_hash)
    if not row then
        release(db)
        return "invalid or expired code"
    end
    exec_one(db, "UPDATE email_otp SET used_at = UNIX_TIMESTAMP() WHERE id = ?", row.id)
    release(db)
    return nil
end

-- ---------------------------------------------------------------------------
-- OAuth links
-- ---------------------------------------------------------------------------

function M.upsert_oauth_link(user_id, provider, subject, email)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO oauth_link (user_id, provider, subject, email) VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE email = VALUES(email), user_id = VALUES(user_id)
    ]], user_id, provider, subject, email)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat: conversations
-- ---------------------------------------------------------------------------

function M.list_conversations(user_id, limit, offset, opts)
    limit  = math.min(limit or 50, 200)
    offset = offset or 0
    opts   = opts or {}
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local archive_filter = opts.archived
        and "AND archived_at IS NOT NULL"
        or  "AND archived_at IS NULL"
    local rows = query_all(db, string.format([[
        SELECT id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens,
               starred, archived_at, memory_disabled,
               created_at,
               updated_at
        FROM chat_conversation
        WHERE user_id = ? AND deleted_at IS NULL %s
        ORDER BY starred DESC, updated_at DESC
        LIMIT %d OFFSET %d
    ]], archive_filter, limit, offset), user_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.create_conversation(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_conversation
            (id, user_id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens,
             created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ]], id, data.user_id, data.gateway_id,
        data.project_id,
        data.title or "New conversation",
        data.model or "",
        data.system_prompt,
        data.temperature or 0.7,
        data.max_tokens or 2048,
        now, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.get_conversation(id, user_id)
    local db, err = get_conn()
    if not db then return nil, err end
    local conv = query_one(db, [[
        SELECT id, user_id, gateway_id, project_id, title, model, system_prompt, temperature, max_tokens,
               starred, archived_at, memory_disabled,
               created_at,
               updated_at
        FROM chat_conversation
        WHERE id = ? AND user_id = ? AND deleted_at IS NULL
        LIMIT 1
    ]], id, user_id)
    if not conv then release(db); return nil, "not_found" end

    -- Load messages
    local msgs = query_all(db, [[
        SELECT id, parent_message_id, role, content,
               input_tokens, output_tokens, cost_usd, latency_ms, gateway_id, model,
               created_at
        FROM chat_message
        WHERE conversation_id = ? AND deleted_at IS NULL
        ORDER BY created_at ASC
    ]], id) or {}
    -- Load attachment metadata for all messages
    if #msgs > 0 then
        local msg_ids = {}
        local msg_idx = {}
        for i, m in ipairs(msgs) do
            msg_ids[i] = "'" .. m.id:gsub("'", "''") .. "'"
            msg_idx[m.id] = m
            m.attachments = setmetatable({}, cjson.array_mt)
        end
        local in_clause = table.concat(msg_ids, ",")
        local atts = query_all(db, string.format([[
            SELECT id, message_id, filename, mime_type, size_bytes,
                   created_at
            FROM chat_attachment WHERE message_id IN (%s)
        ]], in_clause)) or {}
        for _, att in ipairs(atts) do
            local m = msg_idx[att.message_id]
            if m then m.attachments[#m.attachments+1] = att end
        end
    end
    release(db)
    conv.messages = setmetatable(msgs, cjson.array_mt)
    return conv
end

function M.update_conversation(id, user_id, data)
    local db, err = get_conn()
    if not db then return err end
    local sets = {}
    local params = {}
    if data.title         ~= nil then sets[#sets+1] = "title = ?";         params[#params+1] = data.title end
    if data.model         ~= nil then sets[#sets+1] = "model = ?";         params[#params+1] = data.model end
    if data.system_prompt ~= nil then sets[#sets+1] = "system_prompt = ?"; params[#params+1] = data.system_prompt end
    if data.temperature   ~= nil then sets[#sets+1] = "temperature = ?";   params[#params+1] = data.temperature end
    if data.max_tokens    ~= nil then sets[#sets+1] = "max_tokens = ?";    params[#params+1] = data.max_tokens end
    if data.gateway_id    ~= nil then sets[#sets+1] = "gateway_id = ?";    params[#params+1] = data.gateway_id end
    if data.starred          ~= nil then sets[#sets+1] = "starred = ?";          params[#params+1] = data.starred end
    if data.memory_disabled  ~= nil then sets[#sets+1] = "memory_disabled = ?";  params[#params+1] = data.memory_disabled end
    if data.archived_at   ~= nil then
        if data.archived_at == ngx.null then
            sets[#sets+1] = "archived_at = NULL"
        else
            sets[#sets+1] = "archived_at = ?"
            params[#params+1] = data.archived_at
        end
    end
    if #sets == 0 then release(db); return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = math.floor(ngx.now())
    params[#params+1] = id
    params[#params+1] = user_id
    local sql = "UPDATE chat_conversation SET " .. table.concat(sets, ", ") ..
                " WHERE id = ? AND user_id = ? AND deleted_at IS NULL"
    local e = exec_one(db, sql, table.unpack(params))
    release(db)
    return e
end

function M.delete_conversation(id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE chat_conversation SET deleted_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL
    ]], math.floor(ngx.now()), id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat: messages
-- ---------------------------------------------------------------------------

function M.append_message(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = data.created_at or math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_message
            (id, conversation_id, parent_message_id, role, content,
             input_tokens, output_tokens, cost_usd, latency_ms, gateway_id, model, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ]], id, data.conversation_id, data.parent_message_id,
        data.role, data.content,
        data.input_tokens, data.output_tokens,
        data.cost_usd, data.latency_ms, data.gateway_id, data.model, now)
    if not e then
        -- Touch conversation updated_at
        exec_one(db, [[
            UPDATE chat_conversation SET updated_at = ? WHERE id = ?
        ]], now, data.conversation_id)
    end
    release(db)
    if e then return nil, e end
    return id
end

function M.update_message(id, conversation_id, user_id, content)
    -- Simple in-place edit for Phase 1.  Phase 2 adds branching via parent_message_id.
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE chat_message m
        JOIN chat_conversation c ON c.id = m.conversation_id
        SET m.content = ?
        WHERE m.id = ? AND m.conversation_id = ? AND c.user_id = ? AND m.deleted_at IS NULL
    ]], content, id, conversation_id, user_id)
    release(db)
    return e
end

function M.delete_message(id, conversation_id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE chat_message m
        JOIN chat_conversation c ON c.id = m.conversation_id
        SET m.deleted_at = ?
        WHERE m.id = ? AND m.conversation_id = ? AND c.user_id = ? AND m.deleted_at IS NULL
    ]], math.floor(ngx.now()), id, conversation_id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat: attachments
-- ---------------------------------------------------------------------------

function M.insert_attachment(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_attachment (id, message_id, filename, mime_type, size_bytes, data, created_at)
        VALUES (?,?,?,?,?,?,?)
    ]], id, data.message_id, data.filename, data.mime_type, data.size_bytes, data.data, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.get_attachment(id, user_id)
    -- user_id ownership check via conversation join
    local db, err = get_conn()
    if not db then return nil, err end
    local row = query_one(db, [[
        SELECT a.id, a.message_id, a.filename, a.mime_type, a.size_bytes, a.data,
               a.created_at
        FROM chat_attachment a
        JOIN chat_message m    ON m.id = a.message_id
        JOIN chat_conversation c ON c.id = m.conversation_id
        WHERE a.id = ? AND c.user_id = ?
        LIMIT 1
    ]], id, user_id)
    release(db)
    if not row then return nil, "not_found" end
    return row
end

function M.delete_attachment(id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE a FROM chat_attachment a
        JOIN chat_message m ON m.id = a.message_id
        JOIN chat_conversation c ON c.id = m.conversation_id
        WHERE a.id = ? AND c.user_id = ?
    ]], id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat: presets
-- ---------------------------------------------------------------------------

function M.list_presets(user_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, [[
        SELECT id, name, model, system_prompt, temperature, max_tokens,
               created_at,
               updated_at
        FROM chat_preset WHERE user_id = ? ORDER BY name ASC
    ]], user_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.create_preset(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_preset (id, user_id, name, model, system_prompt, temperature, max_tokens, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?)
    ]], id, data.user_id, data.name, data.model or "",
        data.system_prompt, data.temperature, data.max_tokens, now, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.update_preset(id, user_id, data)
    local db, err = get_conn()
    if not db then return err end
    local sets   = {}
    local params = {}
    if data.name          ~= nil then sets[#sets+1] = "name = ?";          params[#params+1] = data.name end
    if data.model         ~= nil then sets[#sets+1] = "model = ?";         params[#params+1] = data.model end
    if data.system_prompt ~= nil then sets[#sets+1] = "system_prompt = ?"; params[#params+1] = data.system_prompt end
    if data.temperature   ~= nil then sets[#sets+1] = "temperature = ?";   params[#params+1] = data.temperature end
    if data.max_tokens    ~= nil then sets[#sets+1] = "max_tokens = ?";    params[#params+1] = data.max_tokens end
    if #sets == 0 then release(db); return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = math.floor(ngx.now())
    params[#params+1] = id
    params[#params+1] = user_id
    local sql = "UPDATE chat_preset SET " .. table.concat(sets, ", ") ..
                " WHERE id = ? AND user_id = ?"
    local e = exec_one(db, sql, table.unpack(params))
    release(db)
    return e
end

function M.delete_preset(id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM chat_preset WHERE id = ? AND user_id = ?", id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat: commands (slash commands)
-- ---------------------------------------------------------------------------

function M.list_commands(user_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, [[
        SELECT id, name, description, template,
               created_at,
               updated_at
        FROM chat_command WHERE user_id = ? ORDER BY name ASC
    ]], user_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.create_command(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_command (id, user_id, name, description, template, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?)
    ]], id, data.user_id, data.name, data.description or "", data.template, now, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.update_command(id, user_id, data)
    local db, err = get_conn()
    if not db then return err end
    local sets   = {}
    local params = {}
    if data.name        ~= nil then sets[#sets+1] = "name = ?";        params[#params+1] = data.name end
    if data.description ~= nil then sets[#sets+1] = "description = ?"; params[#params+1] = data.description end
    if data.template    ~= nil then sets[#sets+1] = "template = ?";    params[#params+1] = data.template end
    if #sets == 0 then release(db); return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = math.floor(ngx.now())
    params[#params+1] = id
    params[#params+1] = user_id
    local sql = "UPDATE chat_command SET " .. table.concat(sets, ", ") ..
                " WHERE id = ? AND user_id = ?"
    local e = exec_one(db, sql, table.unpack(params))
    release(db)
    return e
end

function M.delete_command(id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM chat_command WHERE id = ? AND user_id = ?", id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Chat feedback
-- ---------------------------------------------------------------------------

function M.upsert_feedback(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_feedback (id, conversation_id, user_id, rating, comment, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE rating = VALUES(rating), comment = VALUES(comment), updated_at = VALUES(updated_at)
    ]], id, data.conversation_id, data.user_id, data.rating, data.comment, now, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.get_feedback(conv_id, user_id)
    local db, err = get_conn()
    if not db then return nil, err end
    local row = query_one(db, [[
        SELECT id, conversation_id, user_id, rating, comment, processed,
               created_at,
               updated_at
        FROM chat_feedback
        WHERE conversation_id = ? AND user_id = ?
        LIMIT 1
    ]], conv_id, user_id)
    release(db)
    return row
end

function M.list_feedback(opts)
    local db, err = get_conn()
    if not db then return {} end
    opts = opts or {}
    local limit = math.min(opts.limit or 100, 500)

    local where = "1=1"
    local params = {}
    if opts.processed == true then
        where = where .. " AND f.processed = 1"
    elseif opts.processed == false then
        where = where .. " AND f.processed = 0"
    end

    local sql = string.format([[
        SELECT f.id, f.conversation_id, f.user_id, u.email,
               f.rating, f.comment, f.processed,
               f.created_at,
               f.updated_at
        FROM chat_feedback f
        LEFT JOIN `user` u ON u.id = f.user_id
        WHERE %s
        ORDER BY f.created_at DESC
        LIMIT %d
    ]], where, limit)

    local rows = query_all(db, sql) or {}
    release(db)
    return rows
end

function M.mark_feedback_processed(id)
    local db, err = get_conn()
    if not db then return err end
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        UPDATE chat_feedback SET processed = 1, updated_at = ? WHERE id = ?
    ]], now, id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- OAuth links
-- ---------------------------------------------------------------------------

function M.get_user_by_oauth(provider, subject)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT u.id, u.email, u.name, u.role, u.tenant_id
        FROM oauth_link l
        JOIN `user` u ON u.id = l.user_id
        WHERE l.provider = ? AND l.subject = ?
          AND u.deleted_at IS NULL
        LIMIT 1
    ]], provider, subject)
    release(db)
    return row
end

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

function M.list_projects(tenant_id, user_id, is_admin)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows
    if is_admin then
        rows = query_all(db, string.format([[
            SELECT p.id, p.tenant_id, p.name, p.description, p.instructions,
                   p.icon, p.color, p.default_gateway_id, p.default_model,
                   p.created_by,
                   p.created_at,
                   p.updated_at,
                   (SELECT COUNT(*) FROM chat_project_member  WHERE project_id = p.id) AS member_count,
                   (SELECT COUNT(*) FROM chat_project_knowledge WHERE project_id = p.id) AS knowledge_count,
                   (SELECT MAX(c.updated_at)
                    FROM chat_conversation c WHERE c.project_id = p.id AND c.deleted_at IS NULL) AS last_conversation_at,
                   m.role AS my_role
            FROM chat_project p
            LEFT JOIN chat_project_member m ON m.project_id = p.id AND m.user_id = ?
            WHERE p.tenant_id = ? AND p.deleted_at IS NULL
            ORDER BY p.updated_at DESC
            LIMIT 200
        ]], 200), user_id, tenant_id) or {}
    else
        rows = query_all(db, string.format([[
            SELECT p.id, p.tenant_id, p.name, p.description, p.instructions,
                   p.icon, p.color, p.default_gateway_id, p.default_model,
                   p.created_by,
                   p.created_at,
                   p.updated_at,
                   (SELECT COUNT(*) FROM chat_project_member  WHERE project_id = p.id) AS member_count,
                   (SELECT COUNT(*) FROM chat_project_knowledge WHERE project_id = p.id) AS knowledge_count,
                   (SELECT MAX(c.updated_at)
                    FROM chat_conversation c WHERE c.project_id = p.id AND c.deleted_at IS NULL) AS last_conversation_at,
                   m.role AS my_role
            FROM chat_project p
            JOIN chat_project_member m ON m.project_id = p.id AND m.user_id = ?
            WHERE p.tenant_id = ? AND p.deleted_at IS NULL
            ORDER BY p.updated_at DESC
            LIMIT 200
        ]], 200), user_id, tenant_id) or {}
    end
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.create_project(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_project
            (id, tenant_id, name, description, instructions, icon, color,
             default_gateway_id, default_model, created_by, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ]], id,
        data.tenant_id, data.name,
        data.description, data.instructions,
        data.icon or "📁", data.color or "#2563eb",
        data.default_gateway_id, data.default_model,
        data.created_by, now, now)
    if e then release(db); return nil, e end
    -- Auto-add creator as owner
    local e2 = exec_one(db, [[
        INSERT INTO chat_project_member (project_id, user_id, role, invited_by, joined_at)
        VALUES (?,?,?,?,?)
    ]], id, data.created_by, "owner", data.created_by, now)
    release(db)
    if e2 then return nil, e2 end
    return id
end

function M.get_project(id, user_id, is_admin)
    local db, err = get_conn()
    if not db then return nil, err end
    local proj
    if is_admin then
        proj = query_one(db, [[
            SELECT p.id, p.tenant_id, p.name, p.description, p.instructions,
                   p.icon, p.color, p.default_gateway_id, p.default_model,
                   p.created_by,
                   p.created_at,
                   p.updated_at,
                   NULL AS my_role
            FROM chat_project p
            WHERE p.id = ? AND p.deleted_at IS NULL
            LIMIT 1
        ]], id)
    else
        proj = query_one(db, [[
            SELECT p.id, p.tenant_id, p.name, p.description, p.instructions,
                   p.icon, p.color, p.default_gateway_id, p.default_model,
                   p.created_by,
                   p.created_at,
                   p.updated_at,
                   m.role AS my_role
            FROM chat_project p
            JOIN chat_project_member m ON m.project_id = p.id AND m.user_id = ?
            WHERE p.id = ? AND p.deleted_at IS NULL
            LIMIT 1
        ]], user_id, id)
    end
    if not proj then release(db); return nil, "not_found" end
    -- Load members
    proj.members = query_all(db, [[
        SELECT m.user_id, m.role,
               m.joined_at,
               u.email, u.name
        FROM chat_project_member m
        JOIN `user` u ON u.id = m.user_id
        WHERE m.project_id = ?
        ORDER BY m.joined_at ASC
    ]], id) or {}
    -- Load knowledge file metadata (no text body — that would be large)
    proj.knowledge = query_all(db, [[
        SELECT id, filename, content_type, size_bytes, token_count,
               created_at
        FROM chat_project_knowledge
        WHERE project_id = ?
        ORDER BY created_at ASC
    ]], id) or {}
    proj.members   = setmetatable(proj.members,   cjson.array_mt)
    proj.knowledge = setmetatable(proj.knowledge, cjson.array_mt)
    release(db)
    return proj
end

function M.update_project(id, data)
    local db, err = get_conn()
    if not db then return err end
    local sets, params = {}, {}
    local fields = {"name","description","instructions","icon","color","default_gateway_id","default_model"}
    for _, f in ipairs(fields) do
        if data[f] ~= nil then
            sets[#sets+1] = f .. " = ?"
            params[#params+1] = data[f]
        end
    end
    if #sets == 0 then release(db); return nil end
    sets[#sets+1] = "updated_at = ?"
    params[#params+1] = math.floor(ngx.now())
    params[#params+1] = id
    local e = exec_one(db, "UPDATE chat_project SET " .. table.concat(sets, ", ") .. " WHERE id = ? AND deleted_at IS NULL",
                       table.unpack(params))
    release(db)
    return e
end

function M.delete_project(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE chat_project SET deleted_at = ? WHERE id = ?",
                       math.floor(ngx.now()), id)
    -- Detach conversations
    exec_one(db, "UPDATE chat_conversation SET project_id = NULL WHERE project_id = ?", id)
    -- Hard-delete project-scoped memories (project is gone; memories are meaningless)
    exec_one(db, "DELETE FROM chat_memory WHERE project_id = ?", id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Project members
-- ---------------------------------------------------------------------------

function M.get_project_member(project_id, user_id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT role FROM chat_project_member WHERE project_id = ? AND user_id = ? LIMIT 1
    ]], project_id, user_id)
    release(db)
    return row
end

function M.add_project_member(project_id, user_id, role, invited_by)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO chat_project_member (project_id, user_id, role, invited_by, joined_at)
        VALUES (?,?,?,?,?)
        ON DUPLICATE KEY UPDATE role = VALUES(role)
    ]], project_id, user_id, role, invited_by, math.floor(ngx.now()))
    release(db)
    return e
end

function M.update_project_member_role(project_id, user_id, role)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE chat_project_member SET role = ? WHERE project_id = ? AND user_id = ?
    ]], role, project_id, user_id)
    release(db)
    return e
end

function M.remove_project_member(project_id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM chat_project_member WHERE project_id = ? AND user_id = ?
    ]], project_id, user_id)
    release(db)
    return e
end

function M.count_project_owners(project_id)
    local db, err = get_conn()
    if not db then return 0 end
    local row = query_one(db, [[
        SELECT COUNT(*) AS cnt FROM chat_project_member
        WHERE project_id = ? AND role = 'owner'
    ]], project_id)
    release(db)
    return (row and row.cnt) or 0
end

-- ---------------------------------------------------------------------------
-- Project knowledge
-- ---------------------------------------------------------------------------

function M.list_project_knowledge(project_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, [[
        SELECT id, filename, content_type, size_bytes, token_count,
               COALESCE(source, 'text') AS source,
               created_at
        FROM chat_project_knowledge
        WHERE project_id = ?
        ORDER BY created_at ASC
    ]], project_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.get_project_knowledge_item(kid, project_id)
    -- Returns a single knowledge row including extracted_text
    local db, err = get_conn()
    if not db then return nil, err end
    local rows = query_all(db, [[
        SELECT id, filename, content_type, size_bytes, token_count, extracted_text,
               COALESCE(source, 'text') AS source,
               created_at
        FROM chat_project_knowledge
        WHERE id = ? AND project_id = ?
        LIMIT 1
    ]], kid, project_id) or {}
    release(db)
    return rows[1]
end

function M.get_project_knowledge_text(project_id)
    -- Returns all knowledge rows including extracted_text (used for context injection)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, [[
        SELECT id, filename, token_count, extracted_text
        FROM chat_project_knowledge
        WHERE project_id = ?
        ORDER BY created_at ASC
    ]], project_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.add_project_knowledge(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_project_knowledge
            (id, project_id, filename, content_type, size_bytes, extracted_text, token_count, source, created_by, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
    ]], id, data.project_id, data.filename, data.content_type or "text/plain",
        data.size_bytes or 0, data.extracted_text or "",
        data.token_count or 0, data.source or "text", data.created_by, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.upsert_project_knowledge(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local now = math.floor(ngx.now())
    -- Rough token estimate: ~4 chars per token
    local token_count = math.floor((#(data.extracted_text or "")) / 4)
    local e = exec_one(db, [[
        INSERT INTO chat_project_knowledge
            (id, project_id, filename, content_type, size_bytes, extracted_text, token_count, created_by, created_at)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            extracted_text = VALUES(extracted_text),
            content_type   = VALUES(content_type),
            size_bytes     = VALUES(size_bytes),
            token_count    = VALUES(token_count)
    ]], uuid(), data.project_id, data.filename,
        data.content_type or "text/plain",
        data.size_bytes or 0,
        data.extracted_text or "",
        token_count,
        data.created_by, now)
    release(db)
    if e then return nil, e end
    return true
end

function M.delete_project_knowledge(id, project_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        DELETE FROM chat_project_knowledge WHERE id = ? AND project_id = ?
    ]], id, project_id)
    release(db)
    return e
end

function M.store_project_knowledge_blob(knowledge_id, data)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO chat_project_knowledge_blob (knowledge_id, data) VALUES (?, ?)
    ]], knowledge_id, data)
    release(db)
    return e
end

function M.get_project_knowledge_blob(knowledge_id)
    local db, err = get_conn()
    if not db then return nil, err end
    local rows = query_all(db, [[
        SELECT data FROM chat_project_knowledge_blob WHERE knowledge_id = ?
    ]], knowledge_id)
    release(db)
    return rows and rows[1] and rows[1].data
end

-- ---------------------------------------------------------------------------
-- Chat: share links
-- ---------------------------------------------------------------------------

function M.upsert_share(conv_id, user_id, token, snapshot_json)
    local db, err = get_conn()
    if not db then return nil, err end
    -- Atomic delete-then-insert within the same connection
    exec_one(db, "DELETE FROM chat_share WHERE conversation_id = ?", conv_id)
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_share (id, conversation_id, user_id, token, snapshot_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
    ]], uuid(), conv_id, user_id, token, snapshot_json, now)
    release(db)
    if e then return nil, e end
    return true
end

function M.delete_share(conv_id, user_id)
    local db, err = get_conn()
    if not db then return err end
    exec_one(db, "DELETE FROM chat_share WHERE conversation_id = ? AND user_id = ?",
             conv_id, user_id)
    release(db)
    return nil
end

function M.get_share_by_token(token)
    local db, err = get_conn()
    if not db then return nil, err end
    local row = query_one(db,
        "SELECT conversation_id, user_id, snapshot_json FROM chat_share WHERE token = ?",
        token)
    release(db)
    return row
end

function M.get_share_by_conv(conv_id, user_id)
    local db, err = get_conn()
    if not db then return nil, err end
    local row = query_one(db,
        "SELECT token FROM chat_share WHERE conversation_id = ? AND user_id = ?",
        conv_id, user_id)
    release(db)
    return row
end

-- ---------------------------------------------------------------------------
-- Chat: memories
-- ---------------------------------------------------------------------------

-- list_memories(user_id, project_id)
--   project_id = nil  → return user memories (project_id IS NULL)
--   project_id = <id> → return project-scoped memories for that project
function M.list_memories(user_id, project_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows
    if project_id then
        rows = query_all(db, [[
            SELECT id, user_id, project_id, content, type, source,
                   created_at,
                   updated_at
            FROM chat_memory WHERE user_id = ? AND project_id = ?
            ORDER BY created_at ASC
        ]], user_id, project_id) or {}
    else
        rows = query_all(db, [[
            SELECT id, user_id, project_id, content, type, source,
                   created_at,
                   updated_at
            FROM chat_memory WHERE user_id = ? AND project_id IS NULL
            ORDER BY created_at ASC
        ]], user_id) or {}
    end
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.create_memory(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO chat_memory (id, user_id, project_id, content, type, source, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?)
    ]], id, data.user_id, data.project_id, data.content,
        data.type or "fact", data.source or "manual", now, now)
    release(db)
    if e then return nil, e end
    return id
end

function M.update_memory(id, user_id, content)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE chat_memory SET content = ?, updated_at = ? WHERE id = ? AND user_id = ?
    ]], content, math.floor(ngx.now()), id, user_id)
    release(db)
    return e
end

function M.delete_memory(id, user_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM chat_memory WHERE id = ? AND user_id = ?", id, user_id)
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Conversation embeddings — semantic search
-- ---------------------------------------------------------------------------

function M.upsert_conversation_embedding(conversation_id, user_id, text, embedding_json)
    local db, err = get_conn()
    if not db then return err end
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO conversation_embeddings
            (conversation_id, user_id, text, embedding, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE text = ?, embedding = ?, updated_at = ?
    ]], conversation_id, user_id, text, embedding_json, now, now,
        text, embedding_json, now)
    release(db)
    return e
end

function M.get_user_conversation_embeddings(user_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT conversation_id, embedding
        FROM conversation_embeddings
        WHERE user_id = ?
        ORDER BY updated_at DESC
        LIMIT 500
    ]], user_id) or {}
    release(db)
    return rows
end

function M.search_conversations_by_title(user_id, q, limit)
    limit = math.min(limit or 20, 100)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, string.format([[
        SELECT id, gateway_id, title, model, project_id, starred, archived_at,
               created_at,
               updated_at
        FROM chat_conversation
        WHERE user_id = ? AND deleted_at IS NULL AND archived_at IS NULL
          AND title LIKE ?
        ORDER BY updated_at DESC
        LIMIT %d
    ]], limit), user_id, "%" .. q .. "%") or {}
    release(db)
    return rows
end

-- ---------------------------------------------------------------------------
-- App feedback (AGF-31)
-- ---------------------------------------------------------------------------

function M.insert_app_feedback(entry)
    local db, err = get_conn()
    if not db then return nil, err end
    local e = exec_one(db, [[
        INSERT INTO app_feedback (id, user_id, type, summary, description, url, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], entry.id, entry.user_id, entry.type or "other",
        entry.summary, entry.description, entry.url,
        math.floor(ngx.now()))
    release(db)
    if e then return nil, e end
    return entry.id
end

function M.list_app_feedback(limit, offset, type_filter)
    limit  = math.min(limit or 50, 200)
    offset = offset or 0
    local db, err = get_conn()
    if not db then return {} end
    local rows
    if type_filter and type_filter ~= "" then
        rows = query_all(db, string.format([[
            SELECT f.id, f.user_id, f.type, f.summary, f.description, f.url,
                   f.created_at,
                   f.processed,
                   u.email AS user_email
            FROM app_feedback f LEFT JOIN `user` u ON u.id = f.user_id
            WHERE f.type = ?
            ORDER BY f.created_at DESC
            LIMIT %d OFFSET %d
        ]], limit, offset), type_filter) or {}
    else
        rows = query_all(db, string.format([[
            SELECT f.id, f.user_id, f.type, f.summary, f.description, f.url,
                   f.created_at,
                   f.processed,
                   u.email AS user_email
            FROM app_feedback f LEFT JOIN `user` u ON u.id = f.user_id
            ORDER BY f.created_at DESC
            LIMIT %d OFFSET %d
        ]], limit, offset)) or {}
    end
    release(db)
    return rows
end

function M.update_app_feedback(id, processed)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE app_feedback SET processed = ? WHERE id = ?",
        processed and 1 or 0, id)
    release(db)
    return e
end

-- List conversations for a project (most recent 50)
function M.list_project_conversations(project_id, limit)
    limit = math.min(limit or 50, 200)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, string.format([[
        SELECT id, gateway_id, title, model, project_id,
               created_at,
               updated_at
        FROM chat_conversation
        WHERE project_id = ? AND deleted_at IS NULL
        ORDER BY updated_at DESC
        LIMIT %d
    ]], limit), project_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

-- ---------------------------------------------------------------------------
-- Project feed (shared conversations)
-- ---------------------------------------------------------------------------

-- Mark/unmark a conversation as shared to its project's feed.
function M.set_conversation_shared(conv_id, shared_by, shared)
    local db, err = get_conn()
    if not db then return false, err end
    local now = shared and math.floor(ngx.now()) or nil
    local e
    if shared then
        e = exec_one(db, [[
            UPDATE chat_conversation
            SET    shared_in_project = 1,
                   shared_at         = ?,
                   shared_by         = ?
            WHERE  id = ?
        ]], now, shared_by, conv_id)
    else
        e = exec_one(db, [[
            UPDATE chat_conversation
            SET    shared_in_project = 0,
                   shared_at         = NULL,
                   shared_by         = NULL
            WHERE  id = ?
        ]], conv_id)
    end
    release(db)
    if e then return false, e end
    return true
end

-- List conversations shared to a project feed, newest first.
function M.list_project_feed(project_id, limit, offset)
    limit  = math.min(limit or 20, 100)
    offset = offset or 0
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, string.format([[
        SELECT c.id, c.title, c.model, c.user_id, c.project_id,
               c.shared_at,
               c.shared_by,
               u.email AS shared_by_email,
               c.created_at
        FROM   chat_conversation c
        LEFT JOIN user u ON u.id = c.shared_by
        WHERE  c.project_id = ?
          AND  c.shared_in_project = 1
          AND  c.deleted_at IS NULL
        ORDER  BY c.shared_at DESC
        LIMIT  %d OFFSET %d
    ]], limit, offset), project_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

-- ---------------------------------------------------------------------------
-- Conversation summaries (Infinite Chats)
-- ---------------------------------------------------------------------------

-- Insert a new summary record.
function M.create_conversation_summary(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id = uuid()
    local e = exec_one(db, [[
        INSERT INTO conversation_summary
               (id, conversation_id, summary_text, first_message_id, last_message_id, message_count, model_used, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], id, data.conversation_id, data.summary_text,
        data.first_message_id, data.last_message_id,
        data.message_count or 0, data.model_used or "",
        math.floor(ngx.now()))
    release(db)
    if e then return nil, e end
    data.id = id
    return data
end

-- List all summaries for a conversation, ordered oldest first.
function M.list_conversation_summaries(conversation_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows = query_all(db, [[
        SELECT id, conversation_id, summary_text, first_message_id, last_message_id,
               message_count, model_used,
               created_at
        FROM   conversation_summary
        WHERE  conversation_id = ?
        ORDER  BY created_at ASC
    ]], conversation_id) or {}
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

-- ---------------------------------------------------------------------------
-- MCP connectors
-- ---------------------------------------------------------------------------

function M.list_mcp_connectors(tenant_id, gateway_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end
    local rows
    if gateway_id then
        rows = query_all(db, [[
            SELECT id, tenant_id, gateway_id, name, server_url, auth_type,
                   created_at,
                   updated_at
            FROM   mcp_connector
            WHERE  tenant_id = ? AND gateway_id = ?
            ORDER  BY name ASC
        ]], tenant_id, gateway_id) or {}
    else
        rows = query_all(db, [[
            SELECT id, tenant_id, gateway_id, name, server_url, auth_type,
                   created_at,
                   updated_at
            FROM   mcp_connector
            WHERE  tenant_id = ?
            ORDER  BY name ASC
        ]], tenant_id) or {}
    end
    release(db)
    return setmetatable(rows, cjson.array_mt)
end

function M.get_mcp_connector(id)
    local db, err = get_conn()
    if not db then return nil, err end
    local row = query_one(db, [[
        SELECT id, tenant_id, gateway_id, name, server_url, auth_type, auth_value,
               created_at,
               updated_at
        FROM   mcp_connector
        WHERE  id = ?
    ]], id)
    release(db)
    return row
end

function M.create_mcp_connector(data)
    local db, err = get_conn()
    if not db then return nil, err end
    local id  = uuid()
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        INSERT INTO mcp_connector (id, tenant_id, gateway_id, name, server_url, auth_type, auth_value, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], id, data.tenant_id, data.gateway_id, data.name, data.server_url,
        data.auth_type or "none", data.auth_value, now, now)
    release(db)
    if e then return nil, e end
    data.id         = id
    data.created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
    data.updated_at = data.created_at
    return data
end

function M.update_mcp_connector(id, data)
    local db, err = get_conn()
    if not db then return false, err end
    local now = math.floor(ngx.now())
    local e = exec_one(db, [[
        UPDATE mcp_connector
        SET    name       = COALESCE(?, name),
               server_url = COALESCE(?, server_url),
               auth_type  = COALESCE(?, auth_type),
               auth_value = COALESCE(?, auth_value),
               updated_at = ?
        WHERE  id = ?
    ]], data.name, data.server_url, data.auth_type, data.auth_value, now, id)
    release(db)
    if e then return false, e end
    return true
end

function M.delete_mcp_connector(id)
    local db, err = get_conn()
    if not db then return false, err end
    local e = exec_one(db, "DELETE FROM mcp_connector WHERE id = ?", id)
    release(db)
    if e then return false, e end
    return true
end

return M

