-- utils/email.lua — send email via local sendmail (nullmailer / postfix relay)
-- Uses io.popen("sendmail -t") so no library dependency; nullmailer handles
-- actual SMTP relay to a configured upstream.

local M = {}

local function from_addr()
    local ok, cfg = pcall(require, "core.app_config")
    return (ok and cfg.auth and cfg.auth.otp_from_email) or "noreply@localhost"
end

-- Send a plain-text email.
-- Returns nil on success, or an error string on failure.
function M.send(to, subject, body)
    local msg = table.concat({
        "To: " .. tostring(to),
        "From: " .. from_addr(),
        "Subject: " .. tostring(subject),
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        tostring(body),
        "",   -- trailing newline required by sendmail
    }, "\r\n")

    local pipe, err = io.popen("sendmail -t 2>&1", "w")
    if not pipe then
        return "sendmail unavailable: " .. tostring(err)
    end
    pipe:write(msg)
    local ok2 = pipe:close()
    if not ok2 then
        return "sendmail process failed"
    end
    return nil
end

return M
