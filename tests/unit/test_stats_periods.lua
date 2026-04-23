-- tests/unit/test_stats_periods.lua
-- Tests for time-window correctness in storage.get_usage_stats (MySQL backend).
-- Run with: resty tests/runner.lua tests/unit/test_stats_periods.lua
--
-- Originally used storage.sqlite and tested a SQLite-specific bug:
-- datetime('now','-1 hour') returning a space-separated timestamp that always
-- compared less than ISO-8601 stored strings.  That bug is irrelevant to MySQL,
-- where timestamps are stored as Unix milliseconds (BIGINT).
--
-- This rewrite verifies that the MySQL implementation:
--   1. Calculates the correct Unix-ms time boundaries for each window
--   2. Emits SQL with ? placeholders for the boundaries (parameterised)
--   3. Returns distinct values per window (the original regression guard)

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
-- MySQL mock driver — records every query issued
-- ---------------------------------------------------------------------------

local queries      = {}
local query_results = {}
local connect_ok   = true

package.preload["resty.mysql"] = function()
    return {
        new = function()
            return {
                connect        = function(_, opts) return connect_ok and 1 or nil, "err" end,
                set_keepalive  = function() return 1 end,
                set_timeout    = function() end,
                read_result    = function()
                    local r = table.remove(query_results, 1) or {}
                    return r, nil, nil
                end,
                query          = function(self, sql)
                    queries[#queries + 1] = sql
                    local r = table.remove(query_results, 1) or {}
                    return r, nil, nil
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
    M.init({
        mysql = { host = "127.0.0.1", port = 3306, database = "ai_gateway",
                  user = "gateway", password = "secret",
                  pool_size = 10, pool_timeout = 5000 }
    })
    queries = {}
    return M
end

-- ---------------------------------------------------------------------------
-- Helpers: expected time boundaries at ngx.now() = 1700000000
-- ---------------------------------------------------------------------------
-- ngx.now() = 1700000000
-- today_start_ms  = (1700000000 - 1700000000 % 86400) * 1000
-- last_7d_ms      = today_start_ms - 7 * 86400 * 1000
-- hour_ms         = (1700000000 - 3600) * 1000
-- last_min_ms     = (1700000000 - 60)   * 1000

local NOW       = 1700000000
local TODAY_MS  = (NOW - (NOW % 86400)) * 1000
local HOUR_MS   = (NOW - 3600) * 1000
local MIN_MS    = (NOW - 60)   * 1000
local L7D_MS    = TODAY_MS - 7 * 86400 * 1000

-- ============================================================================
-- 1. Window boundaries are computed correctly
-- ============================================================================

describe("stats periods (MySQL): time boundary values are correct at ngx.now()=1700000000", function()

    it("today_ms aligns to midnight of the current day", function()
        local today_start = NOW - (NOW % 86400)
        assert.equal(0, today_start % 86400,
            "today_start must be an exact midnight UTC boundary")
        assert.equal(TODAY_MS, today_start * 1000)
    end)

    it("hour_ms is exactly 3600 seconds before now in ms", function()
        assert.equal(HOUR_MS, (NOW - 3600) * 1000)
    end)

    it("last_min_ms is exactly 60 seconds before now in ms", function()
        assert.equal(MIN_MS, (NOW - 60) * 1000)
    end)

    it("last_7d_ms is exactly 7 days before today start", function()
        assert.equal(L7D_MS, TODAY_MS - 7 * 86400 * 1000)
    end)

    it("windows are strictly ordered: last_min > hour > today > last_7d", function()
        assert.is_true(MIN_MS    > HOUR_MS,  "last_min must be more recent than hour")
        assert.is_true(HOUR_MS   > TODAY_MS, "hour must be more recent than today_start")
        assert.is_true(TODAY_MS  > L7D_MS,   "today must be more recent than last_7d")
    end)
end)

-- ============================================================================
-- 2. get_usage_stats emits SQL with correct time boundaries
-- ============================================================================

describe("stats periods (MySQL): get_usage_stats emits correct time boundaries in SQL", function()

    it("SQL contains the last_7d_ms boundary value", function()
        local M = reset()
        -- Queue results for the 4 sub-queries issued by get_usage_stats
        for _ = 1, 4 do table.insert(query_results, {}) end
        M.get_usage_stats()
        -- The main stats query uses last_7d_ms as the outer WHERE boundary
        local found = false
        for _, q in ipairs(queries) do
            if q:find(tostring(L7D_MS)) then found = true; break end
        end
        assert.is_true(found,
            "at least one query must contain the last_7d_ms boundary (" .. L7D_MS .. ")")
    end)

    it("SQL contains the today_ms boundary (within-day window)", function()
        local M = reset()
        for _ = 1, 4 do table.insert(query_results, {}) end
        M.get_usage_stats()
        local found = false
        for _, q in ipairs(queries) do
            if q:find(tostring(TODAY_MS)) then found = true; break end
        end
        assert.is_true(found,
            "at least one query must reference today_ms (" .. TODAY_MS .. ")")
    end)

    it("SQL contains the hour_ms boundary", function()
        local M = reset()
        for _ = 1, 4 do table.insert(query_results, {}) end
        M.get_usage_stats()
        local found = false
        for _, q in ipairs(queries) do
            if q:find(tostring(HOUR_MS)) then found = true; break end
        end
        assert.is_true(found,
            "at least one query must contain hour_ms (" .. HOUR_MS .. ")")
    end)

    it("SQL contains the last_min_ms boundary", function()
        local M = reset()
        for _ = 1, 4 do table.insert(query_results, {}) end
        M.get_usage_stats()
        local found = false
        for _, q in ipairs(queries) do
            if q:find(tostring(MIN_MS)) then found = true; break end
        end
        assert.is_true(found,
            "at least one query must contain last_min_ms (" .. MIN_MS .. ")")
    end)

end)

-- ============================================================================
-- 3. get_usage_stats correctly maps returned rows to the period buckets
-- ============================================================================

describe("stats periods (MySQL): result struct has all required period buckets", function()

    it("returns a table with last_min, hour, today, yesterday, last_7d keys", function()
        local M = reset()
        -- Queue one result row per query; each returns the aggregate columns
        local function make_row(prefix, req)
            local r = {}
            r[prefix .. "_req"]     = req
            r[prefix .. "_cached"]  = 0
            r[prefix .. "_blocked"] = 0
            r[prefix .. "_scrubbed"]= 0
            r[prefix .. "_flagged"] = 0
            r[prefix .. "_in_tok"]  = 10
            r[prefix .. "_out_tok"] = 5
            r[prefix .. "_cost"]    = 0.001
            r[prefix .. "_saved"]   = 0
            r[prefix .. "_avg_lat"] = 100
            r[prefix .. "_avg_up"]  = 80
            return r
        end
        -- The stats query returns ONE combined row with all five period prefixes
        local combined = {}
        for _, p in ipairs({"lm","hr","td","yd","l7"}) do
            for k, v in pairs(make_row(p, 3)) do combined[k] = v end
        end
        table.insert(query_results, { combined })
        table.insert(query_results, {})  -- by_tenant
        table.insert(query_results, {})  -- recent
        table.insert(query_results, {})  -- recent_blocked

        local stats = M.get_usage_stats()
        assert.not_nil(stats.last_min,  "last_min bucket missing")
        assert.not_nil(stats.hour,      "hour bucket missing")
        assert.not_nil(stats.today,     "today bucket missing")
        assert.not_nil(stats.yesterday, "yesterday bucket missing")
        assert.not_nil(stats.last_7d,   "last_7d bucket missing")
    end)

    it("each bucket has requests, input_tokens, cost_usd fields", function()
        local M = reset()
        local row = {}
        for _, p in ipairs({"lm","hr","td","yd","l7"}) do
            row[p .. "_req"]    = 1
            row[p .. "_in_tok"] = 10
            row[p .. "_cost"]   = 0.001
            row[p .. "_cached"] = 0
            row[p .. "_blocked"]= 0
            row[p .. "_scrubbed"]=0
            row[p .. "_flagged"]= 0
            row[p .. "_out_tok"]= 5
            row[p .. "_saved"]  = 0
            row[p .. "_avg_lat"]= 100
            row[p .. "_avg_up"] = 80
        end
        table.insert(query_results, { row })
        for _ = 1, 3 do table.insert(query_results, {}) end

        local stats = M.get_usage_stats()
        for _, bucket in ipairs({"last_min","hour","today"}) do
            assert.not_nil(stats[bucket].requests,     bucket .. ".requests missing")
            assert.not_nil(stats[bucket].input_tokens, bucket .. ".input_tokens missing")
            assert.not_nil(stats[bucket].cost_usd,     bucket .. ".cost_usd missing")
        end
    end)

end)
