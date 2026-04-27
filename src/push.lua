-- push.lua — send mobile push notifications to all registered devices of a
-- user. Dispatches to the local APNs microservice (port 8010) for iOS and to
-- the local FCM microservice (port 8011) for Android, based on the platform
-- column in device_token.
--
-- Call only from ngx.timer (non-blocking) — never inline in a request handler.

local http    = require("resty.http")
local json    = require("cjson.safe")
local storage = require("storage.mysql")

local M = {}

local APNS_URL = "http://172.17.0.1:8010/send"
local FCM_URL  = "http://172.17.0.1:8011/send"

local function endpoint_for(platform)
    if platform == "android" then return FCM_URL end
    return APNS_URL
end

-- Fire one push to one device token. On HTTP 410 the microservice signals
-- the token is permanently dead — purge it from the DB so we stop trying.
local function send_one(platform, token, title, body, data)
    local url = endpoint_for(platform)
    local payload = json.encode({
        device_token = token,
        title        = title,
        body         = body,
        data         = data,
    })
    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = payload,
        headers = { ["Content-Type"] = "application/json" },
    })
    if err then
        ngx.log(ngx.WARN, "push: ", platform, " service error: ", err)
        return
    end
    if res.status == 200 then return end
    if res.status == 410 then
        -- Token is dead. Delete to prevent endless retries.
        ngx.log(ngx.NOTICE, "push: deleting dead ", platform, " token: ", res.body)
        storage.delete_device_token(token)
        return
    end
    ngx.log(ngx.WARN, "push: ", platform, " service returned ", res.status, ": ", res.body)
end

-- Send a push notification to all registered devices of a user.
-- title, body: strings. data: optional table (custom payload fields).
-- Fires-and-forgets — errors are logged, not returned.
function M.notify_user(user_id, title, body, data)
    local tokens, err = storage.get_device_tokens(user_id)
    if err or not tokens or #tokens == 0 then return end

    for _, row in ipairs(tokens) do
        local platform = row.platform or "ios"
        local token    = row.token
        ngx.timer.at(0, function()
            send_one(platform, token, title, body, data)
        end)
    end
end

return M
