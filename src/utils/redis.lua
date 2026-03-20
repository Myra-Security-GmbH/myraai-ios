-- utils/redis.lua — lua-resty-redis connection pool wrapper
local redis_lib = require("resty.redis")

local POOL_SIZE    = 100
local POOL_TIMEOUT = 10000  -- ms

local config = {
    host    = os.getenv("REDIS_HOST")    or "127.0.0.1",
    port    = tonumber(os.getenv("REDIS_PORT"))   or 6379,
    auth    = os.getenv("REDIS_AUTH"),
    timeout = 2000,  -- ms
}

local M = {}

-- Acquire a Redis connection from the pool.
-- Returns (red, nil) on success or (nil, err) on failure.
function M.connect()
    local red = redis_lib:new()
    red:set_timeout(config.timeout)

    local ok, err = red:connect(config.host, config.port)
    if not ok then
        return nil, "redis connect: " .. tostring(err)
    end

    if config.auth then
        local auth_ok, auth_err = red:auth(config.auth)
        if not auth_ok then
            return nil, "redis auth: " .. tostring(auth_err)
        end
    end

    return red
end

-- Return a connection to the pool (call instead of close).
function M.release(red)
    if not red then return end
    local ok, err = red:set_keepalive(POOL_TIMEOUT, POOL_SIZE)
    if not ok then
        ngx.log(ngx.WARN, "redis keepalive error: ", err)
    end
end

-- Convenience: run a Lua EVALSHA script, falling back to EVAL if not cached.
-- script_sha must be pre-loaded; this handles NOSCRIPT retry automatically.
function M.eval(red, script, sha, num_keys, ...)
    local res, err = red:evalsha(sha, num_keys, ...)
    if err and err:find("NOSCRIPT", 1, true) then
        res, err = red:eval(script, num_keys, ...)
    end
    return res, err
end

return M
