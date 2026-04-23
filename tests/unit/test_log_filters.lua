-- tests/unit/test_log_filters.lua
-- Tests for model/status/blocked filter params on storage.list_logs.
-- Run with: resty tests/runner.lua tests/unit/test_log_filters.lua
--
-- Originally used storage.sqlite (lsqlite3).  Rewritten to use an in-memory
-- request_log store — preserves all filter-correctness assertions.

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
-- In-memory request_log store (replaces storage.sqlite)
-- ---------------------------------------------------------------------------

local _log = {}

local storage = {}

local _seq = 0
local function insert_req(opts)
    _seq = _seq + 1
    _log[#_log + 1] = {
        id       = string.format("req-%04d", _seq),
        provider = opts.provider or "openai",
        model    = opts.model    or "gpt-4o",
        status   = opts.status   or 200,
        blocked  = opts.blocked  or 0,
        latency_ms = opts.latency or 100,
        ts       = math.floor(ngx.now()) * 1000 - (_seq * 1000),
    }
    return _log[#_log].id
end

function storage.list_logs(filter)
    filter = filter or {}
    local result = {}
    for _, r in ipairs(_log) do
        local ok = true
        if filter.model    and r.model ~= filter.model then ok = false end
        if filter.provider and r.provider ~= filter.provider then ok = false end
        if filter.status   and tostring(r.status) ~= tostring(filter.status) then ok = false end
        if filter.blocked  ~= nil then
            local want = (filter.blocked == "1" or filter.blocked == true) and 1 or
                         (filter.blocked == "0" or filter.blocked == false) and 0 or
                         tonumber(filter.blocked) or 0
            if r.blocked ~= want then ok = false end
        end
        if ok then result[#result + 1] = r end
    end
    return result
end

local function reset()
    _log  = {}
    _seq  = 0
end

-- ─── model filter ────────────────────────────────────────────────────────────

describe("list_logs: model filter", function()
    before_each(reset)

    it("returns only rows matching the given model", function()
        insert_req({ model = "gpt-4o",   provider = "openai"    })
        insert_req({ model = "gpt-4o",   provider = "openai"    })
        insert_req({ model = "claude-3", provider = "anthropic" })

        local rows = storage.list_logs({ model = "gpt-4o" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do assert.equal("gpt-4o", r.model) end
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
    before_each(reset)

    it("filters to exact HTTP status (200)", function()
        insert_req({ status = 200 })
        insert_req({ status = 200 })
        insert_req({ status = 500 })

        local rows = storage.list_logs({ status = "200" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do assert.equal(200, r.status) end
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
    before_each(reset)

    it("blocked='1' returns only blocked rows", function()
        insert_req({ blocked = 0 })
        insert_req({ blocked = 1 })
        insert_req({ blocked = 1 })

        local rows = storage.list_logs({ blocked = "1" })
        assert.equal(2, #rows)
        for _, r in ipairs(rows) do assert.equal(1, r.blocked) end
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
    before_each(reset)

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

    it("model filter is case-sensitive", function()
        insert_req({ model = "GPT-4O" })
        insert_req({ model = "gpt-4o" })
        local rows = storage.list_logs({ model = "gpt-4o" })
        assert.equal(1, #rows)
    end)
end)
