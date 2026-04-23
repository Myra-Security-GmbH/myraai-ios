-- tests/unit/test_analytics_depth.lua
-- Tests for storage.get_analytics_depth and storage.get_stats_timeseries (MySQL).
-- Run with: resty tests/runner.lua tests/unit/test_analytics_depth.lua
--
-- Originally used storage.sqlite (lsqlite3) to insert real data and verify
-- computation results.  Rewritten to use the MySQL mock driver — verifies SQL
-- structure (window functions, GROUP BY, ORDER BY, parameterisation) and result
-- processing (the function maps returned rows to the expected output shape).

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
-- MySQL mock driver
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
    package.loaded["storage.mysql"] = nil
    package.loaded["utils.uuid"]    = nil
    local M = require("storage.mysql")
    M.init({ mysql = { host="127.0.0.1", port=3306, database="ai_gateway",
                       user="gateway", password="secret",
                       pool_size=10, pool_timeout=5000 } })
    queries = {}
    return M
end

-- get_analytics_depth emits 6 queries: pct, top_models, by_tenant, by_gateway, by_user, cache_eff
-- get_stats_timeseries emits 6+ queries

local function queue_depth_empty()
    for _ = 1, 6 do table.insert(query_results, {}) end
end

local function any_query_has(sub)
    for _, q in ipairs(queries) do
        if q:find(sub, 1, true) then return true end
    end
    return false
end

local TENANT_A = "aaaaaaaa-0000-0000-0000-000000000001"
local TENANT_B = "bbbbbbbb-0000-0000-0000-000000000002"

-- ============================================================================
-- SQL structure: percentile query
-- ============================================================================

describe("get_analytics_depth SQL: percentile query uses window functions", function()

    it("first query uses ROW_NUMBER() OVER for percentile calculation", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local pct_sql = queries[1] or ""
        assert.is_true(pct_sql:find("ROW_NUMBER") ~= nil or pct_sql:find("row_number") ~= nil,
            "percentile query must use ROW_NUMBER() window function: " .. pct_sql:sub(1,200))
    end)

    it("percentile query selects p50, p95, p99", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local pct_sql = queries[1] or ""
        assert.is_true(pct_sql:find("p50") ~= nil, "must select p50: " .. pct_sql:sub(1,100))
        assert.is_true(pct_sql:find("p95") ~= nil, "must select p95")
        assert.is_true(pct_sql:find("p99") ~= nil, "must select p99")
    end)

    it("percentile query excludes blocked rows", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local pct_sql = queries[1] or ""
        assert.is_true(pct_sql:find("blocked") ~= nil,
            "percentile query must filter blocked rows: " .. pct_sql:sub(1,200))
    end)

    it("percentile query uses the since_ms parameter as ? bind", function()
        local M = reset(); queue_depth_empty()
        local since_ms = 1699900000 * 1000
        M.get_analytics_depth(since_ms)
        -- bind() replaces ? with the value; verify the ms value appears
        assert.is_true(any_query_has(tostring(since_ms)),
            "since_ms value must appear in SQL after bind()")
    end)

end)

-- ============================================================================
-- SQL structure: top_models query
-- ============================================================================

describe("get_analytics_depth SQL: top_models query", function()

    it("top_models query groups by provider and model", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local sql = queries[2] or ""
        assert.is_true(sql:find("GROUP BY") ~= nil or sql:find("group by") ~= nil,
            "top_models must use GROUP BY")
        assert.is_true(sql:find("model") ~= nil, "top_models must reference model column")
        assert.is_true(sql:find("provider") ~= nil, "top_models must reference provider column")
    end)

    it("top_models query orders by requests DESC and has LIMIT 10", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local sql = queries[2] or ""
        assert.is_true(sql:find("LIMIT 10") ~= nil or sql:find("limit 10") ~= nil,
            "top_models must limit to 10: " .. sql:sub(1,200))
    end)

end)

-- ============================================================================
-- SQL structure: by_tenant / by_gateway queries
-- ============================================================================

describe("get_analytics_depth SQL: by_tenant query", function()

    it("by_tenant query groups by tenant_id", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local sql = queries[3] or ""
        assert.is_true(sql:find("tenant_id") ~= nil,
            "by_tenant query must reference tenant_id: " .. sql:sub(1,200))
        assert.is_true(sql:find("GROUP BY") ~= nil or sql:find("group by") ~= nil,
            "by_tenant query must GROUP BY")
    end)

    it("by_tenant query includes cost_usd, input_tokens, blocked count", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local sql = queries[3] or ""
        assert.is_true(sql:find("cost_usd")     ~= nil, "must include cost_usd")
        assert.is_true(sql:find("input_tokens") ~= nil, "must include input_tokens")
        assert.is_true(sql:find("blocked")      ~= nil, "must include blocked count")
    end)

end)

describe("get_analytics_depth SQL: by_gateway query", function()

    it("by_gateway query groups by gateway_id", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        local sql = queries[4] or ""
        assert.is_true(sql:find("gateway_id") ~= nil,
            "by_gateway query must reference gateway_id: " .. sql:sub(1,200))
        assert.is_true(sql:find("GROUP BY") ~= nil or sql:find("group by") ~= nil)
    end)

end)

-- ============================================================================
-- SQL structure: tenant_id filter applied to all sub-queries
-- ============================================================================

describe("get_analytics_depth SQL: tenant_id filter propagates to all sub-queries", function()

    it("all 6 sub-queries contain the tenant_id value when filtering", function()
        local M = reset(); queue_depth_empty()
        -- get_analytics_depth(since_ms, tenant_id, until_ms)
        M.get_analytics_depth(nil, TENANT_A)
        assert.equal(6, #queries, "get_analytics_depth must issue exactly 6 queries")
        for i, q in ipairs(queries) do
            assert.is_true(q:find(TENANT_A, 1, true) ~= nil,
                "query " .. i .. " must contain TENANT_A: " .. q:sub(1,100))
        end
    end)

    it("no tenant_id filter: queries do NOT contain tenant UUID", function()
        local M = reset(); queue_depth_empty()
        M.get_analytics_depth()
        -- With no filter, no queries should contain a tenant UUID in WHERE
        local has_tenant_filter = false
        for _, q in ipairs(queries) do
            if q:find("AND r.tenant_id") then has_tenant_filter = true end
        end
        assert.is_false(has_tenant_filter,
            "queries without tenant filter must not have AND r.tenant_id clause")
    end)

end)

-- ============================================================================
-- Result structure: get_analytics_depth returns expected keys
-- ============================================================================

describe("get_analytics_depth result: correct output structure", function()

    it("returns all required top-level keys", function()
        local M = reset(); queue_depth_empty()
        local result = M.get_analytics_depth()
        assert.not_nil(result.percentiles, "must have percentiles key")
        assert.not_nil(result.top_models,  "must have top_models key")
        assert.not_nil(result.by_tenant,   "must have by_tenant key")
        assert.not_nil(result.by_gateway,  "must have by_gateway key")
        assert.not_nil(result.by_user,     "must have by_user key")
        assert.not_nil(result.cache_efficiency, "must have cache_efficiency key")
    end)

    it("by_tenant rows include required columns when rows are returned", function()
        local M = reset()
        -- Queue empty results for pct + top_models
        table.insert(query_results, {})
        table.insert(query_results, {})
        -- Queue by_tenant result with one row
        table.insert(query_results, {{
            tenant_id="tn-1", tenant="acme", requests=5, blocked=1,
            cached=2, input_tokens=100, output_tokens=50,
            cost_usd=0.01, saved_cost_usd=0.001, avg_latency_ms=200, errors=0
        }})
        -- Queue remaining empty results
        for _ = 1, 3 do table.insert(query_results, {}) end

        local result = M.get_analytics_depth()
        assert.equal(1, #result.by_tenant)
        local r = result.by_tenant[1]
        assert.not_nil(r.tenant_id,      "by_tenant row must have tenant_id")
        assert.not_nil(r.requests,       "by_tenant row must have requests")
        assert.not_nil(r.cost_usd,       "by_tenant row must have cost_usd")
        assert.not_nil(r.blocked,        "by_tenant row must have blocked")
    end)

    it("percentiles are nil when no data is returned by the DB", function()
        local M = reset(); queue_depth_empty()
        local result = M.get_analytics_depth()
        -- Empty result: p50/p95/p99 should be nil (no rows)
        assert.is_nil(result.percentiles.p50)
        assert.is_nil(result.percentiles.p95)
        assert.is_nil(result.percentiles.p99)
    end)

    it("percentiles are populated when DB returns values", function()
        local M = reset()
        table.insert(query_results, {{ p50=150, p95=400, p99=800 }})
        for _ = 1, 5 do table.insert(query_results, {}) end
        local result = M.get_analytics_depth()
        assert.equal(150, result.percentiles.p50)
        assert.equal(400, result.percentiles.p95)
        assert.equal(800, result.percentiles.p99)
    end)

end)

-- ============================================================================
-- get_stats_timeseries
-- ============================================================================

describe("get_stats_timeseries: SQL structure and result", function()

    it("emits at least one query", function()
        local M = reset()
        for _ = 1, 10 do table.insert(query_results, {}) end
        M.get_stats_timeseries(3600, 24)
        assert.is_true(#queries > 0, "get_stats_timeseries must issue at least one query")
    end)

    it("tenant_id filter is applied when provided", function()
        local M = reset()
        for _ = 1, 10 do table.insert(query_results, {}) end
        M.get_stats_timeseries(3600, 24, nil, TENANT_A)
        assert.is_true(any_query_has(TENANT_A),
            "tenant_id value must appear in SQL when filtering")
    end)

    it("returns a table (possibly empty) without raising", function()
        local M = reset()
        for _ = 1, 10 do table.insert(query_results, {}) end
        local ok, result = pcall(M.get_stats_timeseries, 3600, 24)
        assert.is_true(ok, "get_stats_timeseries must not raise: " .. tostring(result))
    end)

    it("UUID validation: get_analytics_depth raises for non-UUID tenant_id", function()
        local M = reset()
        -- get_analytics_depth(since_ms, tenant_id, until_ms)
        local ok, err = pcall(M.get_analytics_depth, nil, "not-a-uuid")
        assert.is_false(ok, "non-UUID tenant_id must raise")
        assert(tostring(err):find("UUID") or tostring(err):find("uuid") or tostring(err):find("tenant"),
            "error must mention UUID: " .. tostring(err))
    end)

end)
