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

local function get_conn()
    local db, err = mysql_lib:new()
    if not db then return nil, "mysql:new: " .. tostring(err) end
    db:set_timeout(_cfg.pool_timeout or 10000)
    local ok, err2, errno, sqlstate = db:connect({
        host        = _cfg.host     or "127.0.0.1",
        port        = _cfg.port     or 3306,
        database    = _cfg.database or "ai_gateway",
        user        = _cfg.user     or "gateway",
        password    = _cfg.password or "",
        charset     = "utf8mb4",
        max_packet_size = 1024 * 1024,
    })
    if not ok then
        return nil, string.format("mysql connect: %s (errno=%s sqlstate=%s)",
            tostring(err2), tostring(errno), tostring(sqlstate))
    end
    return db
end

local function release(db)
    if db then db:set_keepalive(0, _cfg.pool_size or 50) end
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

local function query_one(db, sql, ...)
    local res, err = db:query(bind(db, sql, ...))
    if not res then return nil, err end
    return nullify(res[1])
end

local function query_all(db, sql, ...)
    local res, err = db:query(bind(db, sql, ...))
    if not res then return setmetatable({}, cjson.array_mt), err end
    for i = 1, #res do nullify(res[i]) end
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

local function schema_path()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*/)") .. "schema_mysql.sql"
end

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

    local fh = io.open(schema_path(), "r")
    if not fh then
        db:close()
        error("schema_mysql.sql not found at " .. schema_path())
    end
    local ddl = fh:read("*a")
    fh:close()

    -- Split on ';' and execute each non-empty statement.
    for stmt in ddl:gmatch("([^;]+)") do
        stmt = stmt:match("^%s*(.-)%s*$")  -- trim whitespace
        if stmt ~= "" and not stmt:match("^%-%-") then
            local res, e = db:query(stmt)
            if not res then
                -- Ignore "Table already exists" (1050) — idempotent
                if not tostring(e):find("1050") then
                    db:close()
                    error("schema error: " .. tostring(e) .. "\nSQL: " .. stmt:sub(1, 200))
                end
            end
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
        SELECT input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k
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
    release(db)
    return e
end

-- ---------------------------------------------------------------------------
-- Tenant write helpers
-- ---------------------------------------------------------------------------

function M.upsert_tenant(slug, plan, budget_usd, budget_period, siem_config)
    local id = uuid()
    local db, err = get_conn()
    if not db then return nil end
    exec_one(db, [[
        INSERT IGNORE INTO tenant (id, slug, plan, budget_usd, budget_period, siem_config)
        VALUES (?,?,?,?,?,?)
    ]], id, slug, plan or "free", budget_usd, budget_period or "monthly", siem_config)
    local row = query_one(db, "SELECT id FROM tenant WHERE slug = ?", slug)
    release(db)
    return row and row.id
end

function M.update_tenant(id, plan, budget_usd, budget_period, siem_config)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE tenant SET plan = ?, budget_usd = ?,
               budget_period = COALESCE(?, budget_period),
               siem_config = ?
        WHERE id = ?
    ]], plan, budget_usd, budget_period, siem_config, id)
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
    if not db then return nil end
    exec_one(db, [[
        INSERT INTO gateway (id, tenant_id, slug, config) VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE config = VALUES(config)
    ]], id, tenant_id, slug, json.encode(config_table or {}))
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

function M.delete_auth_token(token_id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "DELETE FROM auth_token WHERE id = ?", token_id)
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
    local e = exec_one(db, [[
        INSERT INTO `user` (id, tenant_id, email, name, role)
        VALUES (?,?,?,?,?)
    ]], id, tenant_id, email, name, role or "member")
    release(db)
    if e then return nil, e end
    return id
end

function M.update_user(id, email, name, role)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        UPDATE `user` SET email = ?, name = ?, role = ? WHERE id = ?
    ]], email, name, role, id)
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

function M.upsert_model_price(provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT INTO model_price
            (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
        VALUES (?,?,?,?,?,?,UNIX_TIMESTAMP())
        ON DUPLICATE KEY UPDATE
            input_per_1k       = VALUES(input_per_1k),
            output_per_1k      = VALUES(output_per_1k),
            cache_write_per_1k = VALUES(cache_write_per_1k),
            cache_read_per_1k  = VALUES(cache_read_per_1k),
            updated_at         = UNIX_TIMESTAMP()
    ]], provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k)
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

function M.list_tenants()
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, slug, plan, budget_usd, budget_period, siem_config,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM tenant WHERE deleted_at IS NULL ORDER BY created_at DESC
    ]]) or {}
    release(db)
    return rows
end

function M.list_gateways(tenant_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT g.id, g.slug, g.tenant_id, g.config,
               DATE_FORMAT(FROM_UNIXTIME(g.created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM gateway g WHERE g.tenant_id = ? ORDER BY g.created_at DESC
    ]], tenant_id) or {}
    release(db)
    return rows
end

function M.get_gateway_by_id(gateway_id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT g.id, g.slug, g.config, g.tenant_id,
               DATE_FORMAT(FROM_UNIXTIME(g.created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
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
                    THEN DATE_FORMAT(FROM_UNIXTIME(expires_at), '%Y-%m-%dT%H:%i:%sZ') END AS expires_at,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
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
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM provider_config WHERE gateway_id = ? ORDER BY provider, alias
    ]], gateway_id) or {}
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
                    THEN DATE_FORMAT(FROM_UNIXTIME(deleted_at), '%Y-%m-%dT%H:%i:%sZ') END AS deleted_at,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM `user` WHERE id = ?
    ]], id)
    release(db)
    return row
end

function M.list_users(tenant_id)
    local db, err = get_conn()
    if not db then return {} end
    local rows
    if tenant_id then
        rows = query_all(db, [[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   DATE_FORMAT(FROM_UNIXTIME(u.created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at,
                   t.slug AS tenant_slug
            FROM `user` u JOIN tenant t ON t.id = u.tenant_id
            WHERE u.tenant_id = ? AND u.deleted_at IS NULL
            ORDER BY u.created_at DESC
        ]], tenant_id) or {}
    else
        rows = query_all(db, [[
            SELECT u.id, u.tenant_id, u.email, u.name, u.role,
                   DATE_FORMAT(FROM_UNIXTIME(u.created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at,
                   t.slug AS tenant_slug
            FROM `user` u JOIN tenant t ON t.id = u.tenant_id
            WHERE u.deleted_at IS NULL
            ORDER BY u.created_at DESC
        ]]) or {}
    end
    release(db)
    return rows
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
                    THEN DATE_FORMAT(FROM_UNIXTIME(expires_at), '%Y-%m-%dT%H:%i:%sZ') END AS expires_at,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
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
               cache_write_per_1k, cache_read_per_1k,
               DATE_FORMAT(FROM_UNIXTIME(updated_at), '%Y-%m-%dT%H:%i:%sZ') AS updated_at
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
                   cache_write_per_1k, cache_read_per_1k,
                   DATE_FORMAT(FROM_UNIXTIME(updated_at), '%Y-%m-%dT%H:%i:%sZ') AS updated_at
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
               DATE_FORMAT(FROM_UNIXTIME(ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts,
               tenant_id, gateway_id,
               provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cost_usd, latency_ms,
               upstream_latency_ms, guardrail_latency_ms, upstream_attempts,
               fallback_provider, fallback_model, saved_cost_usd, request_size_bytes,
               detectors_fired, scrub_applied, response_raw, trace_id
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
               DATE_FORMAT(FROM_UNIXTIME(ts/1000), '%Y-%m-%dT%H:%i:%sZ') AS ts,
               tenant_id, gateway_id, provider, model, status, cached, blocked,
               blocked_by, block_reason, guardrail_verdict,
               input_tokens, output_tokens, cost_usd, latency_ms,
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

function M.get_usage_stats(tenant_id)
    local db, err = get_conn()
    if not db then return {} end

    local now          = math.floor(ngx.now())
    local today_ms     = (now - (now % 86400)) * 1000
    local yesterday_ms = today_ms - 86400 * 1000
    local last_7d_ms   = today_ms - 7 * 86400 * 1000
    local hour_ms      = (now - 3600) * 1000
    local last_min_ms  = (now - 60) * 1000

    local tenant_clause = ""
    if tenant_id and tenant_id ~= "" then
        if tenant_id:match("^[0-9a-fA-F%-]+$") then
            tenant_clause = " AND tenant_id = " .. db:escape_literal(tenant_id)
        end
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
            ROUND(COALESCE(AVG(CASE WHEN %s THEN upstream_latency_ms END),0)) AS %s_avg_up]],
            cond,p, cond,p, cond,p, cond,p, cond,p,
            cond,p, cond,p, cond,p, cond,p, cond,p, cond,p)
    end

    local all_sql = string.format(
        "SELECT %s, %s, %s, %s, %s FROM request_log WHERE ts >= %d%s",
        pcols("lm", "ts >= " .. last_min_ms),
        pcols("hr", "ts >= " .. hour_ms),
        pcols("td", "ts >= " .. today_ms),
        pcols("yd", string.format("ts >= %d AND ts < %d", yesterday_ms, today_ms)),
        pcols("l7", "1=1"),
        last_7d_ms, tenant_clause)

    local r = query_one(db, all_sql) or {}

    local function extract(p)
        return {
            requests                = r[p.."_req"]     or 0,
            cached                  = r[p.."_cached"]  or 0,
            blocked                 = r[p.."_blocked"] or 0,
            scrubbed                = r[p.."_scrubbed"] or 0,
            flagged                 = r[p.."_flagged"] or 0,
            input_tokens            = r[p.."_in_tok"]  or 0,
            output_tokens           = r[p.."_out_tok"] or 0,
            cost_usd                = r[p.."_cost"]    or 0,
            saved_cost_usd          = r[p.."_saved"]   or 0,
            avg_latency_ms          = r[p.."_avg_lat"] or 0,
            avg_upstream_latency_ms = r[p.."_avg_up"]  or 0,
        }
    end

    local by_tenant_sql = string.format([[
        SELECT r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               COUNT(*) AS requests,
               COALESCE(SUM(r.input_tokens),0)  AS input_tokens,
               COALESCE(SUM(r.output_tokens),0) AS output_tokens,
               ROUND(COALESCE(SUM(r.cost_usd),0),4) AS cost_usd
        FROM request_log r
        LEFT JOIN tenant t ON t.id = r.tenant_id
        WHERE r.ts >= %d%s
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], today_ms, tenant_clause)
    local by_tenant = query_all(db, by_tenant_sql) or {}

    local recent_sql = string.format([[
        SELECT DATE_FORMAT(FROM_UNIXTIME(r.ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts,
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
        LEFT JOIN tenant t ON t.id = r.tenant_id
        %s
        ORDER BY r.ts DESC LIMIT 10
    ]], tenant_id and ("WHERE r.tenant_id = " .. db:escape_literal(tenant_id)) or "")
    local recent = query_all(db, recent_sql) or {}

    local recent_blocked_sql = string.format([[
        SELECT DATE_FORMAT(FROM_UNIXTIME(r.ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts,
               r.tenant_id, COALESCE(t.slug, r.tenant_id) AS tenant,
               r.blocked_by, r.block_reason, r.latency_ms,
               r.guardrail_latency_ms, r.guardrail_verdict,
               r.blocked, r.scrub_applied, r.detectors_fired,
               r.response_raw, r.prompt_scrubbed
        FROM request_log r
        LEFT JOIN tenant t ON t.id = r.tenant_id
        WHERE (r.blocked = 1
           OR r.scrub_applied = 1
           OR (r.detectors_fired IS NOT NULL AND r.detectors_fired != '[]'))%s
        ORDER BY r.ts DESC LIMIT 20
    ]], tenant_clause)
    local recent_blocked = query_all(db, recent_blocked_sql) or {}
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

function M.get_stats_timeseries(bucket_sec, n, end_sec, tenant_id)
    local db, err = get_conn()
    if not db then return setmetatable({}, cjson.array_mt) end

    local ref            = end_sec or math.floor(ngx.now())
    local bms            = bucket_sec * 1000
    local now_bucket_sec = math.floor(ref / bucket_sec) * bucket_sec
    local since_ms       = (now_bucket_sec - (n - 1) * bucket_sec) * 1000

    local tenant_clause = tenant_id and " AND tenant_id = ?" or ""
    local sql = string.format([[
        SELECT (ts DIV %d) * %d AS bucket_ts,
               COUNT(*) AS requests,
               SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
               ROUND(COALESCE(SUM(cost_usd),0),6) AS cost_usd
        FROM request_log
        WHERE ts >= ?%s
        GROUP BY bucket_ts
        ORDER BY bucket_ts ASC
    ]], bms, bms, tenant_clause)

    local rows
    if tenant_id then
        rows = query_all(db, sql, since_ms, tenant_id) or {}
    else
        rows = query_all(db, sql, since_ms) or {}
    end
    release(db)

    local by_ts = {}
    for _, r in ipairs(rows) do by_ts[r.bucket_ts] = r end

    local result = setmetatable({}, cjson.array_mt)
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
-- Analytics depth: latency percentiles + top models (requires MySQL 8.0+)
-- ---------------------------------------------------------------------------

function M.get_analytics_depth(since_ms)
    local db, err = get_conn()
    if not db then return {} end

    local now_ms = math.floor(ngx.now() * 1000)
    local from   = since_ms or (now_ms - 86400 * 1000)

    -- Window functions: ROW_NUMBER() and COUNT(*) OVER () — MySQL 8.0+
    local pct = query_one(db, [[
        SELECT
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.50) AS UNSIGNED) THEN latency_ms END) AS p50,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.95) AS UNSIGNED) THEN latency_ms END) AS p95,
            MAX(CASE WHEN rn <= CAST(CEIL(cnt * 0.99) AS UNSIGNED) THEN latency_ms END) AS p99
        FROM (
            SELECT latency_ms,
                   ROW_NUMBER() OVER (ORDER BY latency_ms) AS rn,
                   COUNT(*)     OVER ()                    AS cnt
            FROM request_log
            WHERE ts >= ? AND latency_ms IS NOT NULL AND blocked = 0
        ) sub
    ]], from) or {}

    local top_models = query_all(db, [[
        SELECT model, provider,
               COUNT(*) AS requests,
               ROUND(COALESCE(SUM(cost_usd),0),4) AS cost_usd,
               ROUND(COALESCE(AVG(latency_ms),0))  AS avg_latency_ms
        FROM request_log
        WHERE ts >= ?
        GROUP BY provider, model
        ORDER BY requests DESC
        LIMIT 10
    ]], from) or {}

    local by_tenant = query_all(db, [[
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
        WHERE r.ts >= ?
        GROUP BY r.tenant_id ORDER BY cost_usd DESC
    ]], from) or {}

    local by_gateway = query_all(db, [[
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
        WHERE r.ts >= ?
        GROUP BY r.gateway_id ORDER BY cost_usd DESC
    ]], from) or {}

    local by_user = query_all(db, [[
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
        WHERE r.ts >= ? AND r.user_id IS NOT NULL
        GROUP BY r.user_id, r.tenant_id ORDER BY cost_usd DESC
        LIMIT 50
    ]], from) or {}

    release(db)
    return {
        percentiles = pct,
        top_models  = top_models,
        by_tenant   = by_tenant,
        by_gateway  = by_gateway,
        by_user     = by_user,
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
               DATE_FORMAT(FROM_UNIXTIME(ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts
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
               DATE_FORMAT(FROM_UNIXTIME(ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts,
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
        SELECT DATE_FORMAT(FROM_UNIXTIME(ts/1000), '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS ts,
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
-- Organization CRUD
-- ---------------------------------------------------------------------------

function M.create_org(id, name, slug)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, [[
        INSERT IGNORE INTO organization (id, name, slug) VALUES (?,?,?)
    ]], id, name, slug)
    release(db)
    return e
end

function M.list_orgs()
    local db, err = get_conn()
    if not db then return {} end
    local rows = query_all(db, [[
        SELECT id, name, slug,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM organization WHERE deleted_at IS NULL ORDER BY name
    ]]) or {}
    release(db)
    return rows
end

function M.get_org(id)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT id, name, slug,
               DATE_FORMAT(FROM_UNIXTIME(created_at), '%Y-%m-%dT%H:%i:%sZ') AS created_at
        FROM organization WHERE id = ? AND deleted_at IS NULL
    ]], id)
    release(db)
    return row
end

function M.update_org(id, name, slug)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE organization SET name=?, slug=? WHERE id=?", name, slug, id)
    release(db)
    return e
end

function M.delete_org(id)
    local db, err = get_conn()
    if not db then return err end
    local e = exec_one(db, "UPDATE organization SET deleted_at=UNIX_TIMESTAMP() WHERE id=?", id)
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
        SELECT id, email, name, role, organization_id
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

function M.get_user_by_oauth(provider, subject)
    local db, err = get_conn()
    if not db then return nil end
    local row = query_one(db, [[
        SELECT u.id, u.email, u.name, u.role, u.organization_id
        FROM oauth_link l
        JOIN `user` u ON u.id = l.user_id
        WHERE l.provider = ? AND l.subject = ?
          AND u.deleted_at IS NULL
        LIMIT 1
    ]], provider, subject)
    release(db)
    return row
end

return M

