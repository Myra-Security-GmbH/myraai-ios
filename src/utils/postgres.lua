-- utils/postgres.lua — pgmoon connection pool wrapper
local pgmoon = require("pgmoon")

local config = {
    host     = os.getenv("POSTGRES_HOST") or "127.0.0.1",
    port     = tonumber(os.getenv("POSTGRES_PORT")) or 5432,
    database = os.getenv("POSTGRES_DB")   or "ai_gateway",
    user     = os.getenv("POSTGRES_USER") or "gateway",
    password = os.getenv("POSTGRES_PASS") or "",
}

local POOL_SIZE    = 50
local POOL_TIMEOUT = 10000  -- ms

local M = {}

function M.connect()
    local pg = pgmoon.new(config)
    local ok, err = pg:connect()
    if not ok then
        return nil, "postgres connect: " .. tostring(err)
    end
    return pg
end

function M.release(pg)
    if not pg then return end
    pg:keepalive(POOL_TIMEOUT, POOL_SIZE)
end

return M
