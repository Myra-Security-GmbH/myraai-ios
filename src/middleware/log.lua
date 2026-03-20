-- middleware/log.lua — emit structured request log (called from log phase)

local logger = require("observability.logger")

local M = {}

function M.run(ctx)
    logger.emit(ctx)
end

return M
