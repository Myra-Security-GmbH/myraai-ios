-- tests/unit/test_ip_allowlist.lua
-- Run with: busted tests/unit/test_ip_allowlist.lua

local called_status
_G.ngx = {
    log    = function() end,
    var    = { remote_addr = "1.2.3.4" },
    header = {},
    status = 200,
    exit   = function(s) called_status = s; error(s) end,
    print  = function() end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local mw = require("middleware.ip_allowlist")

local function ctx(remote_addr, allowlist)
    ngx.var.remote_addr = remote_addr
    return {
        gateway_config = { ip_allowlist = allowlist },
    }
end

describe("middleware.ip_allowlist", function()

    it("allows all when no allowlist configured", function()
        assert.has_no.errors(function() mw.run(ctx("1.2.3.4", nil)) end)
        assert.has_no.errors(function() mw.run(ctx("1.2.3.4", {})) end)
    end)

    it("allows exact IP match", function()
        assert.has_no.errors(function() mw.run(ctx("10.0.0.1", {"10.0.0.1"})) end)
    end)

    it("allows IP within CIDR", function()
        assert.has_no.errors(function() mw.run(ctx("10.0.0.50", {"10.0.0.0/24"})) end)
        assert.has_no.errors(function() mw.run(ctx("192.168.1.100", {"192.168.0.0/16"})) end)
    end)

    it("blocks IP outside CIDR", function()
        assert.has_error(function() mw.run(ctx("10.0.1.1", {"10.0.0.0/24"})) end)
        assert.equal(403, called_status)
    end)

    it("allows when one of multiple CIDRs matches", function()
        assert.has_no.errors(function()
            mw.run(ctx("172.16.0.1", {"10.0.0.0/8", "172.16.0.0/12"}))
        end)
    end)

end)
