-- tests/unit/test_storage_mysql.lua — unit tests for storage/mysql.lua
-- Run with: resty tests/runner.lua tests/unit/test_storage_mysql.lua
--
-- Mocks lua-resty-mysql via package.preload so no live MySQL is needed.
-- Focuses on: bind() escaping, SQL dialect (INSERT IGNORE, ON DUPLICATE KEY
-- UPDATE, FROM_UNIXTIME), upsert patterns, and incr_spend atomicity.

-- ---------------------------------------------------------------------------
-- Minimal ngx stub
-- ---------------------------------------------------------------------------
_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function() end,
    ERR    = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local pass, fail = 0, 0

local function ok(name, cond, msg)
    if cond then
        pass = pass + 1
        print("PASS  " .. name)
    else
        fail = fail + 1
        print("FAIL  " .. name .. (msg and (" — " .. tostring(msg)) or ""))
    end
end

-- ---------------------------------------------------------------------------
-- MySQL driver stub
-- ---------------------------------------------------------------------------

-- Records every query issued so tests can inspect SQL and args.
local queries = {}      -- list of SQL strings after bind()
local query_results = {}  -- queue: each entry is the result for the next query()
local connect_ok    = true
local keepalive_calls = 0

local function default_result()
    return { affected_rows = 1 }
end

local db_instance  -- the "connection" object
db_instance = {
    set_timeout   = function() end,
    connect       = function(self, opts)
        if not connect_ok then return nil, "connection refused" end
        return 1
    end,
    escape_literal = function(self, s)
        -- Minimal SQL string escaping: wrap in single quotes, escape backslash and quote
        s = s:gsub("\\", "\\\\"):gsub("'", "\\'")
        return "'" .. s .. "'"
    end,
    query = function(self, sql)
        table.insert(queries, sql)
        -- Pop from front of queue, or return default result
        if #query_results > 0 then
            return table.remove(query_results, 1)
        end
        return default_result()
    end,
    set_keepalive = function(self, idle, pool)
        keepalive_calls = keepalive_calls + 1
    end,
    close = function(self) end,
}

local mysql_stub = {
    new = function(self)
        return db_instance
    end,
}

-- ---------------------------------------------------------------------------
-- UUID and json stubs
-- ---------------------------------------------------------------------------
local uuid_n = 0
package.preload["utils.uuid"] = function()
    return {
        v4 = function()
            uuid_n = uuid_n + 1
            return string.format("uuid-%04d", uuid_n)
        end,
    }
end

package.preload["utils.json"] = function()
    local cjson = require("cjson.safe")
    return { encode = cjson.encode, decode = cjson.decode }
end

-- Stub resty.mysql via package.preload
package.preload["resty.mysql"] = function() return mysql_stub end

-- ---------------------------------------------------------------------------
-- Helper: fresh module load
-- ---------------------------------------------------------------------------
local function reset_storage(cfg_override)
    package.loaded["storage.mysql"]  = nil
    package.preload["storage.mysql"] = nil   -- prevent stale stubs from test_state_backends
    package.loaded["resty.mysql"]    = nil   -- force use of our stub, not stale from prior test
    package.loaded["utils.uuid"]     = nil
    package.loaded["utils.json"]     = nil
    -- leave resty.mysql stub in place

    queries         = {}
    query_results   = {}
    keepalive_calls = 0
    uuid_n          = 0
    connect_ok      = true

    local M = require("storage.mysql")
    local cfg = cfg_override or {
        mysql = {
            host     = "127.0.0.1",
            port     = 3306,
            database = "ai_gateway",
            user     = "gateway",
            password = "secret",
            pool_size    = 10,
            pool_timeout = 5000,
        }
    }
    M.init(cfg)
    -- reset counters after init (init fires SELECT 1 + release)
    queries         = {}
    keepalive_calls = 0
    return M
end

-- ---------------------------------------------------------------------------
-- 1. bind() — nil values become NULL (no quotes)
-- ---------------------------------------------------------------------------
local M = reset_storage()
M.get_model_pricing("openai", nil)
ok("1. nil arg → NULL in SQL", queries[1]:find("NULL"), queries[1])

-- ---------------------------------------------------------------------------
-- 2. bind() — numbers are unquoted
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.incr_spend("token", "t-1", "2024-01", 12345)
local spend_sql = queries[1] or ""
ok("2. number arg not quoted", spend_sql:find("12345") and not spend_sql:find("'12345'"), spend_sql)

-- ---------------------------------------------------------------------------
-- 3. bind() — strings are single-quoted
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.get_gateway("acme", "main")
local gw_sql = queries[1] or ""
ok("3. string arg is single-quoted", gw_sql:find("'acme'") and gw_sql:find("'main'"), gw_sql)

-- ---------------------------------------------------------------------------
-- 4. bind() — string with single-quote is escaped
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.upsert_tenant("o'reilly", "free", nil, "monthly", nil)
-- The SELECT id query also fires; check the INSERT IGNORE
local insert_sql = queries[1] or ""
ok("4. single-quote in string is escaped", insert_sql:find("\\'"), insert_sql)

-- ---------------------------------------------------------------------------
-- 5. upsert_tenant — uses INSERT IGNORE (not ON CONFLICT)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
-- Two queries fire: INSERT IGNORE, then SELECT id. Queue result for SELECT.
table.insert(query_results, default_result())   -- INSERT IGNORE result
table.insert(query_results, { { id = "tn-1" } }) -- SELECT id result
local tid = M.upsert_tenant("acme", "pro", nil, "monthly", nil)
ok("5a. upsert_tenant uses INSERT IGNORE", queries[1]:find("INSERT IGNORE"), queries[1])
ok("5b. upsert_tenant returns id from SELECT", tid == "tn-1", tid)

-- ---------------------------------------------------------------------------
-- 6. upsert_gateway — uses ON DUPLICATE KEY UPDATE (not INSERT OR IGNORE)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
-- Two queries: INSERT ... ON DUPLICATE KEY UPDATE, then SELECT id
table.insert(query_results, default_result())     -- INSERT result
table.insert(query_results, { { id = "gw-1" } }) -- SELECT id result
local gid = M.upsert_gateway("tn-1", "main", { log_payloads = true })
ok("6a. upsert_gateway uses ON DUPLICATE KEY UPDATE", queries[1]:find("ON DUPLICATE KEY UPDATE"), queries[1])
ok("6b. upsert_gateway returns id from SELECT", gid == "gw-1", gid)

-- ---------------------------------------------------------------------------
-- 7. upsert_provider_config — uses ON DUPLICATE KEY UPDATE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.upsert_provider_config("gw-1", "openai", "default", "enc-key", "nonce-123")
ok("7. upsert_provider_config uses ON DUPLICATE KEY UPDATE",
    queries[1]:find("ON DUPLICATE KEY UPDATE"), queries[1])

-- ---------------------------------------------------------------------------
-- 8. upsert_model_price — uses ON DUPLICATE KEY UPDATE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.upsert_model_price("openai", "gpt-4o", 0.0025, 0.010, nil, nil)
ok("8. upsert_model_price uses ON DUPLICATE KEY UPDATE",
    queries[1]:find("ON DUPLICATE KEY UPDATE"), queries[1])

-- ---------------------------------------------------------------------------
-- 9. incr_spend — atomic upsert with ON DUPLICATE KEY UPDATE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.incr_spend("gateway", "gw-1", "2024-01", 500)
local isql = queries[1] or ""
ok("9a. incr_spend uses ON DUPLICATE KEY UPDATE", isql:find("ON DUPLICATE KEY UPDATE"), isql)
ok("9b. incr_spend accumulates with amount_micro + VALUES(amount_micro)",
    isql:find("amount_micro %+ VALUES%(amount_micro%)"), isql)

-- ---------------------------------------------------------------------------
-- 10. set_user_gateway_access — INSERT IGNORE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.set_user_gateway_access("u-1", "gw-1")
ok("10. set_user_gateway_access uses INSERT IGNORE", queries[1]:find("INSERT IGNORE"), queries[1])

-- ---------------------------------------------------------------------------
-- 11. list_tenants — selects created_at (raw Unix BIGINT, no FROM_UNIXTIME)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_tenants()
ok("11. list_tenants selects created_at", queries[1]:find("created_at") ~= nil, queries[1])
ok("11b. list_tenants filters deleted_at IS NULL",
    queries[1]:find("deleted_at IS NULL") ~= nil, queries[1])

-- ---------------------------------------------------------------------------
-- 12. list_gateways — selects created_at (raw Unix BIGINT, no FROM_UNIXTIME)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_gateways("tn-1")
ok("12. list_gateways selects created_at", queries[1]:find("created_at") ~= nil, queries[1])
ok("12b. list_gateways filters by tenant_id", queries[1]:find("tenant_id") ~= nil, queries[1])

-- ---------------------------------------------------------------------------
-- 13. list_auth_tokens — selects expires_at (raw Unix BIGINT, no FROM_UNIXTIME)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_auth_tokens("gw-1")
ok("13. list_auth_tokens selects expires_at", queries[1]:find("expires_at") ~= nil, queries[1])
ok("13b. list_auth_tokens filters by gateway_id", queries[1]:find("gateway_id") ~= nil, queries[1])

-- ---------------------------------------------------------------------------
-- 14. upsert_routing_rule — INSERT path generates a UUID
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
local new_id = M.upsert_routing_rule("gw-1", nil, 10, {}, {}, true)
ok("14a. upsert_routing_rule INSERT returns new uuid", new_id ~= nil and new_id:match("^uuid%-"), new_id)
ok("14b. INSERT INTO routing_rule fired", queries[1]:find("INSERT INTO routing_rule"), queries[1])

-- ---------------------------------------------------------------------------
-- 15. upsert_routing_rule — UPDATE path (id provided)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
local err_or_id = M.upsert_routing_rule("gw-1", "rule-existing", 5, {}, {}, false)
ok("15a. upsert_routing_rule UPDATE fired", queries[1]:find("UPDATE routing_rule"), queries[1])
-- UPDATE path returns nil (exec_one returns nil on success)
ok("15b. UPDATE path returns nil on success", err_or_id == nil, tostring(err_or_id))

-- ---------------------------------------------------------------------------
-- 16. insert_log — all 41 placeholders filled (no SQLite strftime)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
local e = M.insert_log({
    id = "log-1", tenant_id = "tn-1", gateway_id = "gw-1",
    provider = "openai", model = "gpt-4o",
    status = 200, cached = false,
    input_tokens = 10, output_tokens = 5,
    cost_usd = 0.001, latency_ms = 120, ts = 1700000000000,
    meta = {}, blocked = false, upstream_attempts = 1,
    request_size_bytes = 512,
})
ok("16a. insert_log returns nil on success", e == nil, tostring(e))
ok("16b. INSERT INTO request_log fired", queries[1]:find("INSERT INTO request_log"), queries[1])
-- The ts value should be the raw number, not a strftime call
ok("16c. no strftime in insert_log SQL", not queries[1]:find("strftime"), queries[1])

-- ---------------------------------------------------------------------------
-- 17. insert_client_error — uses INSERT IGNORE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.insert_client_error("err-1", "Something went wrong", nil, "/page", "Mozilla", 1700000000000)
ok("17. insert_client_error uses INSERT IGNORE", queries[1]:find("INSERT IGNORE"), queries[1])

-- ---------------------------------------------------------------------------
-- 18. create_playground_trace — uses INSERT IGNORE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.create_playground_trace("gw-1", "gpt-4o", "playground")
ok("18. create_playground_trace uses INSERT IGNORE", queries[1]:find("INSERT IGNORE"), queries[1])

-- ---------------------------------------------------------------------------
-- 19. insert_semantic_cache — uses INSERT IGNORE
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.insert_semantic_cache("gw-1", "gpt-4o", "hash-abc",
    "[0.1,0.2]", '{"choices":[]}', 0.001, 1700000000, 1700003600)
ok("19. insert_semantic_cache uses INSERT IGNORE", queries[1]:find("INSERT IGNORE"), queries[1])

-- ---------------------------------------------------------------------------
-- 20. get_spend — returns 0 when row not found
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})   -- empty result set
local spend = M.get_spend("gateway", "gw-1", "2024-01")
ok("20. get_spend returns 0 when no row", spend == 0, spend)

-- ---------------------------------------------------------------------------
-- 21. get_spend_history — LIMIT embedded as literal (not bind param)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.get_spend_history("gateway", "gw-1", 6)
ok("21. get_spend_history embeds LIMIT as literal",
    queries[1]:find("LIMIT 6"), queries[1])

-- ---------------------------------------------------------------------------
-- 22. get_gateway — returns nil, "not_found" when no row
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})   -- empty result
local cfg_result, errmsg = M.get_gateway("no-tenant", "no-gw")
ok("22. get_gateway returns nil on not_found", cfg_result == nil)
ok("22b. get_gateway error is 'not_found'", errmsg == "not_found", errmsg)

-- ---------------------------------------------------------------------------
-- 23. get_gateway — merges siem config from tenant when gateway lacks one
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, { {
    tenant_id          = "tn-1",
    gateway_id         = "gw-1",
    config             = '{}',
    tenant_budget_usd  = nil,
    tenant_budget_period = "monthly",
    tenant_siem_config = '{"endpoint":"http://siem"}',
} })
local gw_cfg = M.get_gateway("acme", "main")
ok("23. get_gateway merges siem from tenant",
    gw_cfg and gw_cfg.siem and gw_cfg.siem.endpoint == "http://siem",
    gw_cfg and gw_cfg.siem)

-- ---------------------------------------------------------------------------
-- 24. connection error — public function returns gracefully
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
connect_ok = false
local gw2, err2 = M.get_gateway("x", "y")
ok("24. connect failure returns nil, err", gw2 == nil and err2 ~= nil, tostring(err2))

-- ---------------------------------------------------------------------------
-- 25. release() — set_keepalive called once per successful operation
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
connect_ok = true
table.insert(query_results, default_result())
table.insert(query_results, { { id = "tn-99" } })
M.upsert_tenant("t99", "free", nil, "monthly", nil)
-- Two queries fired (INSERT IGNORE + SELECT id), but only one release()
ok("25. set_keepalive called once per operation", keepalive_calls == 1, keepalive_calls)

-- ---------------------------------------------------------------------------
-- 26. insert_log blocked=true → stores 1 in SQL
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.insert_log({
    id = "log-2", tenant_id = "tn-1", gateway_id = "gw-1",
    provider = "openai", model = "gpt-4o",
    status = 200, cached = false,
    input_tokens = 0, output_tokens = 0,
    cost_usd = 0, latency_ms = 0, ts = 1700000000000,
    meta = {}, blocked = true, upstream_attempts = 0,
    request_size_bytes = 0,
})
-- blocked=true → f.blocked and 1 or 0 → 1 should appear in SQL
ok("26. blocked=true writes 1 in insert_log SQL", queries[1]:find(",1,") or queries[1]:find(" 1,"), queries[1])

-- ---------------------------------------------------------------------------
-- 27. list_logs — LIMIT embedded as literal
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, { { total = 0 } })  -- count query
table.insert(query_results, {})                   -- rows query
M.list_logs({ gateway_id = "gw-1", limit = 25, offset = 0 })
-- One of the queries should contain LIMIT 25
local found_limit = false
for _, q in ipairs(queries) do
    if q:find("LIMIT 25") then found_limit = true end
end
ok("27. list_logs embeds LIMIT as literal", found_limit, table.concat(queries, " | "))

-- ---------------------------------------------------------------------------
-- 28. upsert_model_price — no strftime, uses UNIX_TIMESTAMP()
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.upsert_model_price("anthropic", "claude-sonnet-4-6", 0.003, 0.015, nil, nil)
ok("28. upsert_model_price uses UNIX_TIMESTAMP()", queries[1]:find("UNIX_TIMESTAMP%(%)"), queries[1])
ok("28b. no strftime in upsert_model_price", not queries[1]:find("strftime"), queries[1])

-- ---------------------------------------------------------------------------
-- 29. delete_tenant — soft delete sets deleted_at
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.delete_tenant("tn-1")
ok("29. delete_tenant is a soft delete (UPDATE SET deleted_at)",
    queries[1]:find("UPDATE tenant SET deleted_at"), queries[1])

-- ---------------------------------------------------------------------------
-- 30. delete_gateway — hard delete
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.delete_gateway("gw-1")
ok("30. delete_gateway is a hard delete (DELETE FROM gateway)",
    queries[1]:find("DELETE FROM gateway"), queries[1])

-- ---------------------------------------------------------------------------
-- 31. reset_spend — with period deletes specific row
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.reset_spend("gateway", "gw-1", "2024-01")
ok("31. reset_spend with period deletes specific row",
    queries[1]:find("DELETE FROM spend_ledger") and queries[1]:find("AND period ="), queries[1])

-- ---------------------------------------------------------------------------
-- 32. reset_spend — without period deletes all rows for entity
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.reset_spend("gateway", "gw-1", nil)
ok("32. reset_spend without period deletes all entity rows",
    queries[1]:find("DELETE FROM spend_ledger") and not queries[1]:find("AND period"), queries[1])

-- ---------------------------------------------------------------------------
-- 33. insert_auth_token — returns id on success
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
local token_id, token_err = M.insert_auth_token("gw-1", "hash-xyz", {"read"}, nil, nil, "my-key", nil, nil)
ok("33a. insert_auth_token returns uuid id", token_id ~= nil and token_id:match("^uuid%-"), token_id)
ok("33b. insert_auth_token no error", token_err == nil, tostring(token_err))

-- ---------------------------------------------------------------------------
-- 34. Boolean false → "0" in SQL (not nil)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.upsert_routing_rule("gw-1", nil, 0, {}, {}, false)
-- enabled=false → 0 should appear in the INSERT, not NULL
ok("34. boolean false → 0 in SQL", queries[1]:find(",0%)") or queries[1]:find(", 0,") or queries[1]:find(",0,"), queries[1])

-- ---------------------------------------------------------------------------
-- 35. insert_user — inserts into tenant_id (not organization_id)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
local user_id, user_err = M.insert_user("tn-uuid-1", "alice@example.com", "Alice", "member")
local user_sql = queries[2] or ""  -- queries[1] is the duplicate-check SELECT; INSERT is queries[2]
ok("35a. insert_user returns uuid", user_id ~= nil and user_id:match("^uuid%-"), tostring(user_id))
ok("35b. insert_user no error",     user_err == nil, tostring(user_err))
ok("35c. insert_user uses tenant_id column",
    user_sql:find("tenant_id") ~= nil, user_sql)
ok("35d. insert_user does NOT use organization_id column",
    user_sql:find("organization_id") == nil, user_sql)
ok("35e. insert_user sets correct email",
    user_sql:find("'alice@example%.com'") ~= nil, user_sql)
ok("35f. insert_user sets correct role",
    user_sql:find("'member'") ~= nil, user_sql)

-- ---------------------------------------------------------------------------
-- 36. bootstrap_admin — uses tenant_id (not organization_id)
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
-- No existing admin: first query returns empty set
table.insert(query_results, {})
-- Set env so the function proceeds
local orig_getenv = os.getenv
os.getenv = function(k)
    if k == "AIG_BOOTSTRAP_ADMIN_EMAIL" then return "admin@example.com"
    elseif k == "AIG_BOOTSTRAP_ADMIN_NAME" then return "Admin"
    else return orig_getenv(k) end
end
M.bootstrap_admin()
os.getenv = orig_getenv
local bootstrap_sql = queries[2] or ""
ok("36a. bootstrap_admin uses tenant_id column",
    bootstrap_sql:find("tenant_id") ~= nil, bootstrap_sql)
ok("36b. bootstrap_admin does NOT use organization_id column",
    bootstrap_sql:find("organization_id") == nil, bootstrap_sql)

-- ---------------------------------------------------------------------------
-- 37. upsert_tenant — does NOT include organization_id in INSERT
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
-- INSERT IGNORE returns no rows; SELECT returns id
table.insert(query_results, {})
table.insert(query_results, { { id = "tn-001" } })
local tid = M.upsert_tenant("my-tenant", "free", nil, nil, nil)
local upsert_sql = queries[1] or ""
ok("37a. upsert_tenant does NOT include organization_id",
    upsert_sql:find("organization_id") == nil, upsert_sql)
ok("37b. upsert_tenant returns tenant id", tid == "tn-001", tostring(tid))

-- ---------------------------------------------------------------------------
-- 38. update_tenant — does not include organization_id
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
M.update_tenant("tn-1", "pro", 100, nil, nil)
local update_sql_no_org = queries[1] or ""
ok("38a. update_tenant does NOT include organization_id",
    update_sql_no_org:find("organization_id") == nil, update_sql_no_org)

-- ---------------------------------------------------------------------------
-- 39. list_tenants — with tenant_id filters by id column
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_tenants("tn-abc")
local list_t_sql = queries[1] or ""
ok("39a. list_tenants(tenant_id) filters by id = ?",
    list_t_sql:find("AND id") ~= nil or list_t_sql:find("AND `id`") ~= nil, list_t_sql)
ok("39b. list_tenants(tenant_id) does NOT filter by organization_id",
    list_t_sql:find("organization_id") == nil, list_t_sql)

-- list_tenants() without tenant_id should return all (no id filter)
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_tenants()
local list_t_all_sql = queries[1] or ""
ok("39c. list_tenants() without arg does NOT filter by id",
    list_t_all_sql:find("AND id") == nil and list_t_all_sql:find("AND `id`") == nil, list_t_all_sql)

-- ---------------------------------------------------------------------------
-- 40. list_logs — tenant_id filter uses direct column
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.list_logs({ tenant_id = "tn-xyz" })
local list_logs_sql = queries[1] or ""
ok("40a. list_logs(tenant_id) filters by tenant_id column",
    list_logs_sql:find("tenant_id") ~= nil, list_logs_sql)
ok("40b. list_logs(tenant_id) does NOT use organization_id",
    list_logs_sql:find("organization_id") == nil, list_logs_sql)

-- ---------------------------------------------------------------------------
-- 41. get_usage_stats — tenant_id filter uses direct column
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
-- stats query + by_tenant + recent + recent_blocked
for _ = 1, 4 do table.insert(query_results, {}) end
M.get_usage_stats("aabbccdd-0000-0000-0000-000000000001")
local found_org_subq = false
for _, q in ipairs(queries) do
    if q:find("organization_id") then found_org_subq = true end
end
ok("41. get_usage_stats(tenant_id) does NOT use organization_id subquery", not found_org_subq,
    table.concat(queries, " | "):sub(1, 200))

-- ---------------------------------------------------------------------------
-- 42. get_stats_timeseries — tenant_id uses direct column
-- ---------------------------------------------------------------------------
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.get_stats_timeseries(3600, 24, nil, "aabbccdd-0000-0000-0000-000000000002")
local ts_sql = queries[1] or ""
ok("42. get_stats_timeseries(tenant_id) does NOT use organization_id subquery",
    ts_sql:find("organization_id") == nil, ts_sql)

-- ---------------------------------------------------------------------------
-- 43. delete_auth_token — gateway_id filter (Finding 4 IDOR fix)
-- ---------------------------------------------------------------------------

-- 43a: with gateway_id → DELETE WHERE id = ? AND gateway_id = ?
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.delete_auth_token("token-uuid-1", "gateway-uuid-1")
local del_gw_sql = queries[1] or ""
ok("43a. delete_auth_token(id, gateway_id) adds AND gateway_id = ? filter",
    del_gw_sql:find("gateway_id") ~= nil,
    "SQL should contain gateway_id: " .. del_gw_sql)
ok("43b. delete_auth_token(id, gateway_id) still deletes by id",
    del_gw_sql:find("id") ~= nil,
    "SQL should still contain id: " .. del_gw_sql)
-- bind() substitutes ? with quoted values; check both values appear in the SQL
ok("43c. delete_auth_token(id, gateway_id) embeds both token_id and gateway_id values",
    del_gw_sql:find("token%-uuid%-1") ~= nil and del_gw_sql:find("gateway%-uuid%-1") ~= nil,
    "SQL should embed both ids: " .. del_gw_sql)

-- 43d: without gateway_id → DELETE WHERE id = ? (backward compat for /me/tokens)
reset_storage()
M = require("storage.mysql")
table.insert(query_results, {})
M.delete_auth_token("token-uuid-2")
local del_no_gw_sql = queries[1] or ""
ok("43d. delete_auth_token(id) without gateway_id uses simple WHERE id = ?",
    del_no_gw_sql:find("gateway_id") == nil,
    "SQL without gateway_id arg should NOT contain gateway_id: " .. del_no_gw_sql)
ok("43e. delete_auth_token(id) without gateway_id only embeds token_id value",
    del_no_gw_sql:find("token%-uuid%-2") ~= nil,
    "SQL should embed the token_id: " .. del_no_gw_sql)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
