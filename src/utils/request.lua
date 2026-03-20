-- utils/request.lua — nginx request helpers

local M = {}

-- Read and return the raw request body string, handling the case where
-- nginx buffered a large body to a temp file (client_body_buffer_size exceeded).
-- Returns nil if the body is genuinely absent or unreadable.
function M.read_body()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then return data end

    local path = ngx.req.get_body_file()
    if path then
        local fh = io.open(path, "rb")
        if fh then
            data = fh:read("*a")
            fh:close()
            return data
        end
    end
end

return M
