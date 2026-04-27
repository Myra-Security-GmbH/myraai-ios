-- push.lua — send APNs push notifications via the local Python microservice.
-- The microservice listens on 127.0.0.1:8010 (myra-apns.service).
-- Call only from ngx.timer (non-blocking) — never inline in a request handler.

local http = require("resty.http")
local json = require("cjson.safe")
local storage = require("storage.mysql")

local M = {}

local APNS_SERVICE_URL = "http://172.17.0.1:8010/send"

-- Send a push notification to all registered devices of a user.
-- title, body: strings. data: optional table (custom payload fields).
-- Fires-and-forgets — errors are logged, not returned.
function M.notify_user(user_id, title, body, data)
    local tokens, err = storage.get_device_tokens(user_id)
    if err or not tokens or #tokens == 0 then return end

    for _, row in ipairs(tokens) do
        local payload = json.encode({
            device_token = row.token,
            title        = title,
            body         = body,
            data         = data,
        })
        ngx.timer.at(0, function()
            local httpc = http.new()
            httpc:set_timeout(10000)
            local res, req_err = httpc:request_uri(APNS_SERVICE_URL, {
                method  = "POST",
                body    = payload,
                headers = { ["Content-Type"] = "application/json" },
            })
            if req_err then
                ngx.log(ngx.WARN, "push: APNs service error for user ", user_id, ": ", req_err)
            elseif res.status ~= 200 then
                ngx.log(ngx.WARN, "push: APNs service returned ", res.status, " for user ", user_id, ": ", res.body)
            end
        end)
    end
end

return M
