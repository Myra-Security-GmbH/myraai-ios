-- tests/unit/test_log_filters.lua
-- Tests for model/status/blocked filter params added to storage.list_logs.
-- Run with: resty tests/runner.lua tests/unit/test_log_filters.lua

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

rawset(_G, "sqlite3", {})
local sqlite3 = require("lsqlite3")

local CFG_PATH = "/tmp/test_gw_cfg_logfilt.db"
local LOG_PATH = "/tmp/test_gw_log_logfilt.db"
os.remove(CFG_PATH)
os.remove(LOG_PATH)

local storage = require("storage.sqlite")
local cfg = { sqlite = { config_db = CFG_PATH, logs_db = LOG_PATH } }
storage.migrate(cfg)
storage.init(cfg)

local insert_db = sqlite3.open(LOG_PATH)
local seq = 0

local function insert_req(opts)
    seq = seq + 1
    local id = string.format("req-%04d", seq)
    local ts_ms = math.floor(ngx.now()) * 1000 - (seq * 1000)
    local sql = string.format([[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status,
             cached, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens,
             cost_usd, latency_ms, ts,
             meta, blocked, upstream_attempts, request_size_bytes, scrub_applied)
        VALUES ('%s','t1','g1','%s','%s',%d,
                0,10,20,0,0,
                0.001,%d,
                %d,
                '{}', %d, 1, 512, 0)
    ]], id,
        opts.provider or "openai",
        opts.model    or "gpt-4o",
        opts.status   or 200,
        opts.latency  or 100,
        ts_ms,
        opts.blocked  or 0)
    insert_db:exec(sql)
    return id
end

-- ─── model filter ───────────────────────────────────────────────────────────

describe("list_logs: model filter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("returns only rows matching the given model", function()
        insert_req({ model = "gpt-4o",   provider = "openai"    })
        insert_req({ model = "gpt-4o",   provider = "openai"    })
        insert_req({ model = "claude-3", provider = "anthropic" })

        local rows = storage.list_logs({ model = "gpt-4o" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do
            assert.equal("gpt-4o", r.model)
        end
    end)

    it("returns empty when model not present", function()
        insert_req({ model = "gpt-4o" })
        local rows = storage.list_logs({ model = "mistral-7b" })
        assert.equal(0, #rows)
    end)

    it("returns all rows when model filter absent", function()
        insert_req({ model = "gpt-4o"  })
        insert_req({ model = "claude-3" })
        local rows = storage.list_logs({})
        assert.equal(2, #rows)
    end)
end)

-- ─── status filter ───────────────────────────────────────────────────────────

describe("list_logs: status filter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("filters to exact HTTP status (200)", function()
        insert_req({ status = 200 })
        insert_req({ status = 200 })
        insert_req({ status = 500 })

        local rows = storage.list_logs({ status = "200" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do
            assert.equal(200, r.status)
        end
    end)

    it("filters to status 500", function()
        insert_req({ status = 200 })
        insert_req({ status = 500 })
        insert_req({ status = 500 })
        local rows = storage.list_logs({ status = "500" })
        assert.equal(2, #rows)
    end)

    it("returns all rows when status filter absent", function()
        insert_req({ status = 200 })
        insert_req({ status = 500 })
        local rows = storage.list_logs({})
        assert.equal(2, #rows)
    end)
end)

-- ─── blocked filter ──────────────────────────────────────────────────────────

describe("list_logs: blocked filter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("blocked='1' returns only blocked rows", function()
        insert_req({ blocked = 0 })
        insert_req({ blocked = 1 })
        insert_req({ blocked = 1 })

        local rows = storage.list_logs({ blocked = "1" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do
            assert.equal(1, r.blocked)
        end
    end)

    it("blocked=true also selects only blocked rows", function()
        insert_req({ blocked = 0 })
        insert_req({ blocked = 1 })
        local rows = storage.list_logs({ blocked = true })
        assert.equal(1, #rows)
        assert.equal(1, rows[1].blocked)
    end)

    it("absent blocked filter returns all rows", function()
        insert_req({ blocked = 0 })
        insert_req({ blocked = 1 })
        local rows = storage.list_logs({})
        assert.equal(2, #rows)
    end)
end)

-- ─── combined filters ────────────────────────────────────────────────────────

describe("list_logs: combined filters", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("model + blocked combined narrows results", function()
        insert_req({ model = "gpt-4o",   blocked = 1 })
        insert_req({ model = "gpt-4o",   blocked = 0 })
        insert_req({ model = "claude-3", blocked = 1 })

        local rows = storage.list_logs({ model = "gpt-4o", blocked = "1" })
        assert.equal(1, #rows)
        assert.equal("gpt-4o", rows[1].model)
        assert.equal(1,        rows[1].blocked)
    end)

    it("provider + model + status triple filter", function()
        insert_req({ provider = "openai",    model = "gpt-4o",   status = 200 })
        insert_req({ provider = "openai",    model = "gpt-4o",   status = 500 })
        insert_req({ provider = "anthropic", model = "claude-3", status = 200 })

        local rows = storage.list_logs({ provider = "openai", model = "gpt-4o", status = "200" })
        assert.equal(1, #rows)
        assert.equal("openai", rows[1].provider)
        assert.equal("gpt-4o", rows[1].model)
        assert.equal(200,      rows[1].status)
    end)

    it("model filter is case-sensitive (SQLite default)", function()
        insert_req({ model = "GPT-4O" })
        insert_req({ model = "gpt-4o" })
        local rows = storage.list_logs({ model = "gpt-4o" })
        assert.equal(1, #rows)
    end)
end)
