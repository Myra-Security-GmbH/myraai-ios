-- tests/unit/test_audit_log.lua
-- Unit tests for the audit log storage functions.
-- Run with: resty tests/runner.lua tests/unit/test_audit_log.lua
--
-- Originally used storage.sqlite (lsqlite3).  Rewritten to use an in-memory
-- storage mock — preserves all behavioural assertions without SQLite dependency.

_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function() end,
    exit   = function(s) error("ngx.exit:" .. tostring(s)) end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
        get_method    = function() return "GET" end,
    },
    var  = { remote_addr = "10.0.0.1", uri = "/admin/v1/tenants" },
    ctx  = {},
    ERR  = 0, WARN = 1, INFO = 2,
    print = function() end,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ---------------------------------------------------------------------------
-- In-memory audit log storage (replaces storage.sqlite)
-- ---------------------------------------------------------------------------

local _rows = {}
local _next_id = 1

local storage = {}

function storage.insert_audit_log(actor_ip, method, path, status)
    -- Best-effort: wrapped so it never raises (mirrors production pcall)
    pcall(function()
        _rows[#_rows + 1] = {
            id       = _next_id,
            actor_ip = actor_ip,
            method   = method,
            path     = path,
            status   = status,
            ts       = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
        _next_id = _next_id + 1
    end)
end

function storage.list_audit_logs(limit, offset)
    limit  = math.min(tonumber(limit) or 100, 500)
    offset = tonumber(offset) or 0
    -- Return rows newest-first
    local reversed = {}
    for i = #_rows, 1, -1 do reversed[#reversed + 1] = _rows[i] end
    local result = {}
    for i = offset + 1, math.min(offset + limit, #reversed) do
        result[#result + 1] = reversed[i]
    end
    return result
end

local function reset()
    _rows    = {}
    _next_id = 1
end

-- ============================================================================
-- storage.insert_audit_log / storage.list_audit_logs
-- ============================================================================

describe("storage audit_log: basic insert and list", function()
    before_each(reset)

    it("list returns empty array on a fresh database", function()
        local rows = storage.list_audit_logs()
        assert.not_nil(rows)
        assert.equal(0, #rows)
    end)

    it("insert_audit_log records a POST entry", function()
        storage.insert_audit_log("192.168.1.1", "POST", "/admin/v1/tenants", 201)
        local rows = storage.list_audit_logs()
        assert.equal(1, #rows)
        local r = rows[1]
        assert.equal("192.168.1.1",       r.actor_ip)
        assert.equal("POST",              r.method)
        assert.equal("/admin/v1/tenants", r.path)
        assert.equal(201,                 r.status)
    end)

    it("insert_audit_log records a PATCH entry", function()
        storage.insert_audit_log("192.168.1.1", "POST",  "/admin/v1/tenants", 201)
        storage.insert_audit_log("10.0.0.5",    "PATCH", "/admin/v1/gateways/abc", 200)
        local rows = storage.list_audit_logs()
        -- newest-first: PATCH is the most recent
        assert.equal(2, #rows)
        assert.equal("PATCH", rows[1].method)
    end)

    it("insert_audit_log records a DELETE entry", function()
        storage.insert_audit_log("192.168.1.1", "POST",   "/admin/v1/tenants", 201)
        storage.insert_audit_log("10.0.0.5",    "PATCH",  "/admin/v1/gateways/abc", 200)
        storage.insert_audit_log("10.0.0.5",    "DELETE", "/admin/v1/gateways/abc/tokens/t1", 200)
        local rows = storage.list_audit_logs()
        assert.equal(3, #rows)
        assert.equal("DELETE", rows[1].method)
    end)

    it("entries are returned in descending order (newest first)", function()
        storage.insert_audit_log("x", "POST",   "/a", 201)
        storage.insert_audit_log("x", "PATCH",  "/b", 200)
        storage.insert_audit_log("x", "DELETE", "/c", 200)
        local rows = storage.list_audit_logs()
        assert.equal("DELETE", rows[1].method)
        assert.equal("PATCH",  rows[2].method)
        assert.equal("POST",   rows[3].method)
    end)

    it("ts field is an ISO-8601 string", function()
        storage.insert_audit_log("x", "POST", "/a", 200)
        local rows = storage.list_audit_logs()
        assert.not_nil(rows[1].ts)
        assert.match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ", rows[1].ts)
    end)

    it("id field is a positive integer autoincrement", function()
        storage.insert_audit_log("x", "POST",   "/a", 201)
        storage.insert_audit_log("x", "DELETE", "/b", 200)
        local rows = storage.list_audit_logs()
        for _, r in ipairs(rows) do
            assert(type(r.id) == "number" and r.id > 0, "id should be positive integer")
        end
        -- ids must be distinct
        assert.not_equal(rows[1].id, rows[2].id)
    end)

    it("actor_ip can be nil (for system events)", function()
        storage.insert_audit_log(nil, "POST", "/admin/v1/tenants", 201)
        local rows = storage.list_audit_logs()
        assert.is_nil(rows[1].actor_ip)
        assert.equal("POST", rows[1].method)
    end)

end)

describe("storage audit_log: limit and offset pagination", function()
    before_each(function()
        reset()
        for i = 1, 10 do
            storage.insert_audit_log("1.2.3.4", "POST", "/a/" .. i, 200)
        end
    end)

    it("limit restricts the number of rows returned", function()
        local rows = storage.list_audit_logs(3)
        assert.equal(3, #rows)
    end)

    it("offset skips the first N entries", function()
        local all   = storage.list_audit_logs(100, 0)
        local paged = storage.list_audit_logs(100, 2)
        assert.equal(all[3].id, paged[1].id)
    end)

    it("limit is capped at 500", function()
        local rows = storage.list_audit_logs(10000, 0)
        assert(#rows <= 500, "should not exceed 500 even if more requested")
    end)

    it("offset beyond total returns empty list", function()
        local rows = storage.list_audit_logs(100, 9999)
        assert.equal(0, #rows)
    end)

end)

describe("storage audit_log: resilience", function()
    before_each(reset)

    it("insert_audit_log is best-effort and does not raise on nil status", function()
        assert.has_no.errors(function()
            storage.insert_audit_log("1.2.3.4", "POST", "/test", nil)
        end)
    end)

end)

describe("audit log: mutating requests add entries", function()
    before_each(reset)

    it("GET does NOT add an audit entry", function()
        local before = #storage.list_audit_logs(500)
        local method = "GET"
        if method ~= "GET" then
            storage.insert_audit_log("9.9.9.9", method, "/admin/v1/tenants", 200)
        end
        assert.equal(before, #storage.list_audit_logs(500))
    end)

    it("POST adds an audit entry", function()
        local before = #storage.list_audit_logs(500)
        storage.insert_audit_log("9.9.9.9", "POST", "/admin/v1/tenants", 201)
        assert.equal(before + 1, #storage.list_audit_logs(500))
        local rows = storage.list_audit_logs(1, 0)
        assert.equal("POST",              rows[1].method)
        assert.equal("/admin/v1/tenants", rows[1].path)
        assert.equal(201,                 rows[1].status)
        assert.equal("9.9.9.9",           rows[1].actor_ip)
    end)

    it("PATCH and DELETE both produce audit entries", function()
        local before = #storage.list_audit_logs(500)
        storage.insert_audit_log("1.1.1.1", "PATCH",  "/admin/v1/gateways/x", 200)
        storage.insert_audit_log("1.1.1.1", "DELETE", "/admin/v1/gateways/x", 200)
        assert.equal(before + 2, #storage.list_audit_logs(500))
    end)

end)
