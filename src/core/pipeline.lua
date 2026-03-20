-- core/pipeline.lua — ordered middleware chain execution
--
-- Each middleware module must expose:
--   middleware.run(ctx)  → returns nil on success, or calls errors.send() to abort

local M = {}

-- Execute a list of middleware modules in order.
-- Stops on the first one that calls ngx.exit (caught via pcall on the
-- fact that ngx.exit raises an internal nginx error code).
function M.run(middlewares)
    for _, mod_name in ipairs(middlewares) do
        local ok, mod = pcall(require, mod_name)
        if not ok then
            ngx.log(ngx.ERR, "Failed to load middleware: ", mod_name, " — ", mod)
            require("core.errors").send("INTERNAL", "Middleware load failure: " .. mod_name)
            return
        end
        local run_ok, err = pcall(mod.run, ngx.ctx)
        if not run_ok then
            -- ngx.exit() internally raises, propagate it up
            if type(err) == "number" then
                error(err)  -- re-raise nginx exit code
            end
            ngx.log(ngx.ERR, "Middleware error in ", mod_name, ": ", tostring(err))
            require("core.errors").send("INTERNAL")
            return
        end
    end
end

return M
