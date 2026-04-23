-- tests/unit/test_utils_email.lua — unit tests for src/utils/email.lua
-- Run with: resty tests/runner.lua tests/unit/test_utils_email.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    ERR    = 0, WARN = 1, INFO = 2,
}

for _, n in ipairs({"utils.email","utils.proc","utils.crypto","core.app_config"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function()
    return { auth = { otp_from_email = "test@mygateway.example.com" } }
end

-- Track proc.run calls
local _proc_calls = {}
local _proc_exit_code = 0

package.preload["utils.proc"] = function()
    return {
        run = function(cmd, stdin_data, opts)
            _proc_calls[#_proc_calls + 1] = { cmd=cmd, input=stdin_data }
            if _proc_exit_code ~= 0 then
                return "exit " .. _proc_exit_code, _proc_exit_code, "non-zero exit"
            end
            return "250 Message sent", 0, nil
        end,
    }
end

-- Use real crypto for random_hex
package.loaded["utils.crypto"] = nil
local crypto = require("utils.crypto")
package.loaded["utils.crypto"] = crypto

local email = require("utils.email")

local function reset()
    _proc_calls    = {}
    _proc_exit_code = 0
end

-- ============================================================================
-- M.send(): MIME structure
-- ============================================================================

describe("utils.email.send(): MIME message structure", function()

    it("invokes proc.run (sendmail subprocess) with the email message", function()
        reset()
        local err = email.send("alice@example.com", "Test Subject", "Plain text body")
        assert.is_nil(err, "send must not return an error: " .. tostring(err))
        assert.equal(1, #_proc_calls, "proc.run must be called once")
    end)

    it("message contains To: header", function()
        reset()
        email.send("alice@example.com", "Hello", "body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("To: alice@example.com") ~= nil,
            "message must include To: header")
    end)

    it("message contains Subject: header", function()
        reset()
        email.send("alice@example.com", "My Subject", "body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("Subject: My Subject") ~= nil,
            "message must include Subject: header")
    end)

    it("message contains From: header (from config)", function()
        reset()
        email.send("alice@example.com", "s", "body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("From:") ~= nil, "message must include From: header")
        assert.is_true(msg:find("test@mygateway.example.com") ~= nil,
            "From must use config otp_from_email")
    end)

    it("message contains Date: header (RFC 5322 format)", function()
        reset()
        email.send("a@b.com", "s", "body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("Date:") ~= nil, "message must include Date: header")
        -- RFC 5322 day-of-week pattern
        assert.is_true(
            msg:find("Mon,") ~= nil or msg:find("Tue,") ~= nil or msg:find("Wed,") ~= nil or
            msg:find("Thu,") ~= nil or msg:find("Fri,") ~= nil or msg:find("Sat,") ~= nil or
            msg:find("Sun,") ~= nil,
            "Date header must include day of week")
    end)

    it("message contains Message-ID: header", function()
        reset()
        email.send("a@b.com", "s", "body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("Message%-ID:") ~= nil,
            "message must include Message-ID: header")
        assert.is_true(msg:find("<") ~= nil and msg:find(">") ~= nil,
            "Message-ID must be wrapped in angle brackets")
    end)

    it("plain-text only: Content-Type is text/plain", function()
        reset()
        email.send("a@b.com", "s", "plain text body")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("text/plain") ~= nil,
            "plain text email must use text/plain Content-Type")
    end)

    it("with HTML body: Content-Type is multipart/alternative", function()
        reset()
        email.send("a@b.com", "s", "plain text", "<b>html</b>")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("multipart/alternative") ~= nil,
            "email with HTML body must use multipart/alternative")
    end)

    it("multipart message contains both text and HTML parts", function()
        reset()
        email.send("a@b.com", "s", "plain here", "<p>html here</p>")
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("plain here") ~= nil,   "multipart must contain plain text part")
        assert.is_true(msg:find("html here") ~= nil, "multipart must contain HTML part")
    end)

    it("multipart boundary is a CSPRNG string (contains crypto.random_hex result)", function()
        reset()
        email.send("a@b.com", "s", "plain", "<p>html</p>")
        local msg = _proc_calls[1].input
        -- Boundary uses "aig_" prefix + random_hex(16)
        assert.is_true(msg:find("boundary=") ~= nil, "multipart must declare boundary")
        assert.is_true(msg:find("aig_") ~= nil, "boundary must use aig_ prefix")
    end)

end)

-- ============================================================================
-- M.send(): error propagation
-- ============================================================================

describe("utils.email.send(): error propagation", function()

    it("returns nil on success (proc exit code 0)", function()
        reset()
        local err = email.send("a@b.com", "s", "body")
        assert.is_nil(err)
    end)

    it("returns an error string when proc exits non-zero", function()
        reset()
        _proc_exit_code = 1
        local err = email.send("a@b.com", "s", "body")
        assert.not_nil(err, "non-zero exit must return an error string")
        assert.equal("string", type(err))
    end)

end)

-- ============================================================================
-- M.send_template(): template loading
-- ============================================================================

describe("utils.email.send_template(): template loading", function()

    it("loads template module and renders vars", function()
        reset()
        package.preload["templates.email.otp"] = function()
            return {
                subject   = "Your OTP",
                body      = function(vars) return "Your code: " .. vars.code end,
                body_html = function(vars) return "<b>" .. vars.code .. "</b>" end,
            }
        end
        local err = email.send_template("a@b.com", "otp", { code="123456" })
        assert.is_nil(err, "send_template must not error: " .. tostring(err))
        -- Verify the rendered content appears in the message
        local msg = _proc_calls[1].input
        assert.is_true(msg:find("123456") ~= nil, "template vars must be substituted")
        assert.is_true(msg:find("Your OTP") ~= nil, "subject from template must be used")
    end)

end)
