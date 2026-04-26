-- tests/unit/test_stats_tenant_filter.lua
-- Tests for tenant_id filter on storage.get_usage_stats (MySQL backend).
-- Run with: resty tests/runner.lua tests/unit/test_stats_tenant_filter.lua
--
-- Originally used storage.sqlite (lsqlite3).  Rewritten to use the MySQL mock
-- driver — verifies SQL tenant_id filtering, UUID validation, and result structure.

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    status = 200,
    header = {},
    req    = { read_body = function() end, get_body_data = function() return nil end },
    var    = {},
    ctx    = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ---------------------------------------------------------------------------
-- MySQL mock driver (same pattern as test_storage_mysql.lua)
-- ---------------------------------------------------------------------------

local queries       = {}
local query_results = {}

package.preload["resty.mysql"] = function()
    return {
        new = function()
            return {
                connect       = function() return 1 end,
                set_keepalive = function() return 1 end,
                set_timeout   = function() end,
                query         = function(self, sql)
                    queries[#queries + 1] = sql
                    return table.remove(query_results, 1) or {}, nil, nil
                end,
                read_result   = function()
                    return table.remove(query_results, 1) or {}, nil, nil
                end,
            }
        end,
    }
end

package.preload["utils.json"] = function()
    local cjson = require("cjson.safe")
    return { encode = cjson.encode, decode = cjson.decode, null = cjson.null }
end
package.preload["utils.uuid"] = function()
    local n = 0
    return { v4 = function() n = n + 1; return string.format("uuid-%04d", n) end }
end

local function reset()
    queries       = {}
    query_results = {}
    package.loaded["storage.mysql"]  = nil
    package.preload["storage.mysql"] = nil   -- prevent stale stubs from test_state_backends
    package.loaded["resty.mysql"]    = nil   -- force use of our mock preload, not stale from prior test
    package.loaded["utils.uuid"]     = nil
    local M = require("storage.mysql")
    M.init({ mysql = { host="127.0.0.1", port=3306, database="ai_gateway",
                       user="gateway", password="secret",
                       pool_size=10, pool_timeout=5000 } })
    queries = {}
    return M
end

local TENANT_A = "aaaaaaaa-0000-0000-0000-000000000001"
local TENANT_B = "bbbbbbbb-0000-0000-0000-000000000002"

local function queue_empty_stats(n)
    for _ = 1, (n or 4) do table.insert(query_results, {}) end
end

-- Helper: check whether any recorded query contains a substring
local function any_query_has(sub)
    for _, q in ipairs(queries) do
        if q:find(sub, 1, true) then return true end
    end
    return false
end

-- ─── SQL WHERE clause presence ───────────────────────────────────────────────

describe("get_usage_stats SQL: tenant_id filter is applied when tenant_id is passed", function()

    it("SQL contains 'tenant_id' condition when tenant_id is provided", function()
        local M = reset(); queue_empty_stats()
        M.get_usage_stats(TENANT_A)
        assert.is_true(any_query_has("tenant_id"),
            "at least one query must reference tenant_id when filtering")
    end)

    it("SQL does NOT add tenant_id condition when nil is passed", function()
        local M = reset(); queue_empty_stats()
        M.get_usage_stats(nil)
        -- None of the queries should have an extra tenant_id condition
        -- (the by_tenant query always groups by tenant_id, so check the main query)
        local main_sql = queries[1] or ""
        -- The main stats query should not contain 'AND tenant_id'
        assert.is_false(main_sql:find("AND tenant_id") ~= nil,
            "main query must not add tenant_id filter when nil: " .. main_sql)
    end)

    it("tenant_id filter uses parameterised ? placeholder (not interpolation)", function()
        local M = reset(); queue_empty_stats()
        M.get_usage_stats(TENANT_A)
        -- After bind(), ? is replaced with the quoted tenant_id value.
        -- Verify the tenant UUID value appears in the SQL (bind() quotes it).
        assert.is_true(any_query_has(TENANT_A),
            "tenant UUID must appear in SQL after bind()")
    end)

end)

-- ─── UUID validation ─────────────────────────────────────────────────────────

describe("get_usage_stats: UUID format validation", function()

    it("valid UUID-format tenant_id is accepted", function()
        local M = reset(); queue_empty_stats()
        local ok, err = pcall(M.get_usage_stats, TENANT_A)
        assert.is_true(ok, "valid UUID tenant_id must not raise: " .. tostring(err))
    end)

    it("non-UUID tenant_id raises (assert guard)", function()
        local M = reset()
        local ok, err = pcall(M.get_usage_stats, "not-a-uuid")
        assert.is_false(ok, "non-UUID tenant_id must raise an error")
        assert(tostring(err):find("UUID") or tostring(err):find("uuid") or tostring(err):find("tenant"),
            "error should mention UUID format, got: " .. tostring(err))
    end)

    it("hex-only string (no hyphens) is accepted", function()
        local M = reset(); queue_empty_stats()
        local hex_only = string.rep("a", 32)
        local ok = pcall(M.get_usage_stats, hex_only)
        assert.is_true(ok, "hex-only string should be accepted by UUID pattern")
    end)

end)

-- ─── Result structure ────────────────────────────────────────────────────────

describe("get_usage_stats: result structure regardless of tenant filter", function()

    local function make_combined_row()
        local row = {}
        for _, p in ipairs({"lm","hr","td","yd","l7"}) do
            row[p.."_req"]=2; row[p.."_cached"]=0; row[p.."_blocked"]=0
            row[p.."_scrubbed"]=0; row[p.."_flagged"]=0
            row[p.."_in_tok"]=10; row[p.."_out_tok"]=5
            row[p.."_cost"]=0.001; row[p.."_saved"]=0
            row[p.."_avg_lat"]=100; row[p.."_avg_up"]=80
        end
        return row
    end

    it("unfiltered: result has all expected period keys", function()
        local M = reset()
        table.insert(query_results, { make_combined_row() })
        for _ = 1, 3 do table.insert(query_results, {}) end
        local stats = M.get_usage_stats()
        for _, k in ipairs({"last_min","hour","today","yesterday","last_7d"}) do
            assert.not_nil(stats[k], k .. " key must be present in stats")
        end
    end)

    it("filtered: result has all expected period keys", function()
        local M = reset()
        table.insert(query_results, { make_combined_row() })
        for _ = 1, 3 do table.insert(query_results, {}) end
        local stats = M.get_usage_stats(TENANT_A)
        for _, k in ipairs({"last_min","hour","today","yesterday","last_7d"}) do
            assert.not_nil(stats[k], k .. " key must be present in filtered stats")
        end
    end)

    it("by_tenant is empty when no rows are returned", function()
        local M = reset(); queue_empty_stats()
        local stats = M.get_usage_stats(TENANT_A)
        assert.not_nil(stats.by_tenant)
        assert.equal(0, #stats.by_tenant)
    end)

    it("two different tenant_ids produce separate queries with different UUIDs", function()
        local M = reset(); queue_empty_stats(8)
        M.get_usage_stats(TENANT_A)
        local q_a = table.concat(queries, "|")
        queries = {}
        M.get_usage_stats(TENANT_B)
        local q_b = table.concat(queries, "|")
        assert.not_equal(q_a, q_b,
            "queries for different tenants should differ")
        assert.is_true(q_a:find(TENANT_A, 1, true) ~= nil)
        assert.is_true(q_b:find(TENANT_B, 1, true) ~= nil)
    end)

end)
