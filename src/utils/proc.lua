-- utils/proc.lua — non-blocking subprocess execution via ngx.pipe (cosocket-based).
-- Replaces io.popen / os.execute in request-handler and timer contexts so that
-- the nginx worker yields to the event loop while the subprocess runs.
--
-- ngx.pipe API (verified from /usr/local/openresty/lualib/ngx/pipe.lua):
--   pipe.spawn(args_table, opts)  -- opts: merge_stderr, buffer_size, environ
--   proc:set_timeouts(write_ms, stdout_read_ms, stderr_read_ms, wait_ms)
--   proc:stdin_write(data)  proc:shutdown("stdin")   -- NOT stdin_close()
--   proc:stdout_read_all()
--   proc:wait()  → ok (bool|nil), reason ("exit"|"signal"|err_msg), status
--   proc:kill(signal)
--
-- merge_stderr=true is mandatory: leaving stderr unread risks deadlock if the
-- subprocess fills the OS pipe buffer while we block on stdout_read_all().

local pipe = require("ngx.pipe")

local M = {}

-- Run cmd (table of strings, first element = executable path or name).
-- stdin_data (string|nil): written to stdin then EOF signalled via shutdown.
-- opts.timeout_ms: all four pipe timeouts (write/stdout/stderr/wait); default 60 000 ms.
-- Returns: stdout (string), exit_code (number), err (string|nil)
function M.run(cmd, stdin_data, opts)
    opts = opts or {}
    local ms = opts.timeout_ms or 60000

    local proc, err = pipe.spawn(cmd, { merge_stderr = true })
    if not proc then
        return "", -1, "spawn failed: " .. tostring(err)
    end

    -- Arg order: write, stdout_read, stderr_read, wait
    proc:set_timeouts(ms, ms, ms, ms)

    if stdin_data ~= nil then
        local ok_w, err_w = proc:stdin_write(stdin_data)
        if not ok_w then
            proc:kill(9)
            return "", -1, "stdin write failed: " .. tostring(err_w)
        end
        proc:shutdown("stdin")  -- signal EOF to the subprocess
    end

    local stdout, err_r = proc:stdout_read_all()
    stdout = stdout or ""
    if err_r then
        proc:kill(9)
        return stdout, -1, "read failed: " .. tostring(err_r)
    end

    local ok_w, reason, status = proc:wait()
    if ok_w == nil then
        return stdout, -1, "wait failed: " .. tostring(reason)
    end

    local code = tonumber(status) or (ok_w and 0 or -1)
    return stdout, code, (ok_w and nil or reason)
end

return M
