-- utils/email.lua — send email via local sendmail (msmtp relay)
-- Uses io.popen("sendmail -t") so no library dependency.
-- Supports multipart/alternative (text + html) when an html body is supplied.

local crypto = require("utils.crypto")

local M = {}

local function from_addr()
    local ok, cfg = pcall(require, "core.app_config")
    return (ok and cfg.auth and cfg.auth.otp_from_email) or "noreply@localhost"
end

-- RFC 5322 §3.3 date-time: "Day, DD Mon YYYY HH:MM:SS +0000"
local MONTHS = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
local DAYS   = { "Sun","Mon","Tue","Wed","Thu","Fri","Sat" }
local function rfc5322_date()
    local t = os.date("!*t")   -- UTC broken-down time
    return string.format("%s, %02d %s %04d %02d:%02d:%02d +0000",
        DAYS[t.wday], t.day, MONTHS[t.month], t.year, t.hour, t.min, t.sec)
end

-- RFC 5322 §3.6.4 msg-id
local function make_message_id(from)
    local domain = from:match("@([^%s>]+)") or "localhost"
    local ts  = string.format("%x", math.floor(ngx.now() * 1000))
    local rnd = crypto.random_hex(8)
    return "<" .. ts .. "." .. rnd .. "@" .. domain .. ">"
end

-- Build a multipart/alternative message (text + html).
local function build_multipart(plain, html)
    local boundary = "aig_" .. crypto.random_hex(16)
    local parts = {
        "--" .. boundary,
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        tostring(plain),
        "",
        "--" .. boundary,
        "Content-Type: text/html; charset=UTF-8",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        tostring(html),
        "",
        "--" .. boundary .. "--",
    }
    return "multipart/alternative; boundary=\"" .. boundary .. "\"",
           table.concat(parts, "\r\n")
end

-- Send an email.
-- plain: required plain-text body.
-- html:  optional HTML body. When provided the message is sent as
--        multipart/alternative; otherwise as plain text/plain.
-- Returns nil on success, or an error string on failure.
function M.send(to, subject, plain, html)
    local from = from_addr()

    local content_type, body
    if html and html ~= "" then
        content_type, body = build_multipart(plain, html)
    else
        content_type = "text/plain; charset=UTF-8"
        body = tostring(plain) .. "\r\n"
    end

    local msg = table.concat({
        "Date: "         .. rfc5322_date(),
        "Message-ID: "   .. make_message_id(from),
        "To: "           .. tostring(to),
        "From: "         .. from,
        "Subject: "      .. tostring(subject),
        "MIME-Version: 1.0",
        "Content-Type: " .. content_type,
        "",
        body,
    }, "\r\n")

    ngx.log(ngx.NOTICE, "email: sending to=", to, " subject=", subject, " from=", from)

    local pipe, err = io.popen("sendmail -t 2>&1", "w")
    if not pipe then
        local errmsg = "sendmail unavailable: " .. tostring(err)
        ngx.log(ngx.ERR, "email: ", errmsg)
        return errmsg
    end
    pipe:write(msg)
    local ok2, reason, code = pipe:close()
    if not ok2 then
        local errmsg = "sendmail process failed (exit " .. tostring(code) .. ")"
        if reason then errmsg = errmsg .. ": " .. tostring(reason) end
        ngx.log(ngx.ERR, "email: ", errmsg, " to=", to)
        return errmsg
    end
    ngx.log(ngx.NOTICE, "email: sent ok to=", to)
    return nil
end

-- Send a templated email.
-- Template modules expose: subject (string), body(vars) → plain text,
-- and optionally body_html(vars) → HTML.
-- Returns nil on success, or an error string on failure.
function M.send_template(to, template_name, vars)
    local ok, tmpl = pcall(require, "templates.email." .. template_name)
    if not ok then
        return "unknown email template: " .. tostring(template_name)
    end
    local plain = tmpl.body(vars or {})
    local html  = tmpl.body_html and tmpl.body_html(vars or {}) or nil
    return M.send(to, tmpl.subject, plain, html)
end

return M
