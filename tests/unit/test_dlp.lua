-- tests/unit/test_dlp.lua — unit tests for middleware/dlp.lua
-- Run with: busted tests/unit/test_dlp.lua

local called_status
_G.ngx = {
    now    = function() return 1700000000 end,
    log    = function() end,
    req    = { read_body = function() end, get_body_data = function() return nil end,
               set_body_data = function(_, d) end },
    var    = {},
    header = {},
    status = 200,
    exit   = function(s) called_status = s; error(s) end,
    print  = function() end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Clear stale mocks left by earlier test files in the same runner process
for _, n in ipairs({"middleware.dlp","core.errors","utils.json","utils.request"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

local dlp = require("middleware.dlp")

local function make_ctx(action, patterns, body_str)
    return {
        tenant_id  = "t1",
        gateway_id = "g1",
        raw_request_body = body_str,
        gateway_config = {
            dlp = { enabled = true, action = action, patterns = patterns }
        }
    }
end

describe("middleware.dlp", function()

    it("passes clean requests", function()
        local ctx = make_ctx("block", {"email"}, '{"messages":[{"role":"user","content":"Hello!"}]}')
        assert.has_no.errors(function() dlp.run(ctx) end)
    end)

    it("blocks requests containing email when action=block", function()
        local ctx = make_ctx("block", {"email"},
            '{"messages":[{"role":"user","content":"email me at foo@bar.com"}]}')
        assert.has_error(function() dlp.run(ctx) end)
        assert.equal(400, called_status)
    end)

    it("scrubs email when action=scrub", function()
        local ctx = make_ctx("scrub", {"email"},
            '{"messages":[{"role":"user","content":"email me at foo@bar.com please"}]}')
        dlp.run(ctx)
        assert.not_nil(ctx.raw_request_body:find("%[REDACTED%]"))
        assert.is_nil(ctx.raw_request_body:find("foo@bar.com"))
    end)

    it("flags but does not block when action=flag", function()
        local ctx = make_ctx("flag", {"email"},
            '{"messages":[{"role":"user","content":"email me at foo@bar.com"}]}')
        assert.has_no.errors(function() dlp.run(ctx) end)
        assert.equal("email", ctx.dlp_flagged)
    end)

    it("skips when dlp not configured", function()
        local ctx = {
            tenant_id = "t1", gateway_id = "g1",
            raw_request_body = '{"messages":[]}',
            gateway_config   = {},
        }
        assert.has_no.errors(function() dlp.run(ctx) end)
    end)

end)
