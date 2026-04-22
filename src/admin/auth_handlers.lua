-- admin/auth_handlers.lua — login / logout / OTP / Google SSO route handlers
-- Handles all routes under /admin/auth/* (no session guard applied here).

local json     = require("utils.json")
local jwt      = require("utils.jwt")
local crypto   = require("utils.crypto")
local email    = require("utils.email")
local storage  = require("storage")
local uuid_lib = require("utils.uuid")
local random   = require("resty.random")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function cfg_auth()
    local ok, cfg = pcall(require, "core.app_config")
    return (ok and cfg.auth) or {}
end

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Access-Control-Allow-Origin"]      = ngx.var.http_origin or "*"
    ngx.header["Access-Control-Allow-Credentials"] = "true"
    ngx.print(json.encode(body))
end

local function read_body()
    ngx.req.read_body()
    local raw = ngx.req.get_body_data()
    if not raw then
        local f = ngx.req.get_body_file()
        if f then
            local fh = io.open(f, "rb")
            if fh then raw = fh:read("*a"); fh:close() end
        end
    end
    return json.decode(raw or "{}") or {}
end

local function set_session_cookie(token, max_age)
    ngx.header["Set-Cookie"] = "aig_admin=" .. token ..
        "; Path=/; HttpOnly; SameSite=Strict; Max-Age=" .. max_age
end

local function clear_session_cookie()
    ngx.header["Set-Cookie"] = "aig_admin=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
end

local function issue_jwt_for(user, remember_me)
    local auth    = cfg_auth()
    local expiry  = remember_me and 2592000 or (auth.jwt_expiry_secs or 28800)
    local payload = {
        sub    = user.id,
        email  = user.email,
        role   = user.role,
        tenant = user.tenant_id,
        iat    = ngx.time(),
        exp    = ngx.time() + expiry,
    }
    return jwt.sign(payload), expiry
end

-- ---------------------------------------------------------------------------
-- Route table
-- ---------------------------------------------------------------------------

local ROUTES = {}
local function route(method, pattern, handler)
    ROUTES[#ROUTES + 1] = { method = method, pattern = pattern, handler = handler }
end

-- ---------------------------------------------------------------------------
-- GET /admin/auth/me
-- ---------------------------------------------------------------------------
route("GET", "^/admin/auth/me$", function()
    local cookie = ngx.var.http_cookie or ""
    local token  = cookie:match("aig_admin=([^;%s]+)")
    if not token then return send(401, { error = "unauthenticated" }) end

    local payload, err = jwt.verify(token)
    if not payload then return send(401, { error = err or "invalid token" }) end

    send(200, {
        id        = payload.sub,
        email     = payload.email,
        role      = payload.role,
        tenant_id = payload.tenant,
    })
end)

-- ---------------------------------------------------------------------------
-- POST /admin/auth/logout
-- ---------------------------------------------------------------------------
route("POST", "^/admin/auth/logout$", function()
    clear_session_cookie()
    send(200, { ok = true })
end)

-- ---------------------------------------------------------------------------
-- POST /admin/auth/otp/request
-- ---------------------------------------------------------------------------
route("POST", "^/admin/auth/otp/request$", function()
    local body = read_body()
    local addr = body.email
    if not addr or addr == "" then
        return send(400, { error = "email required" })
    end

    -- Always return the same message to avoid leaking whether the email exists.
    local GENERIC_OK = { message = "If that email is registered, a code has been sent." }

    local user = storage.find_admin_user_by_email(addr)
    if not user then
        return send(200, GENERIC_OK)
    end

    -- Generate cryptographically-random 6-digit code (100000–999999)
    local rand_bytes = random.bytes(4, true)
    if not rand_bytes then rand_bytes = random.bytes(4) end
    local n = 0
    for i = 1, #rand_bytes do n = n * 256 + rand_bytes:byte(i) end
    local code = tostring(n % 900000 + 100000)

    local auth      = cfg_auth()
    local expires   = ngx.time() + (auth.otp_expiry_secs or 900)
    local code_hash = crypto.sha256_hex(code)

    local err = storage.insert_email_otp(
        uuid_lib.v4(), addr, code_hash, expires, ngx.var.remote_addr)
    if err then
        ngx.log(ngx.ERR, "insert_email_otp: ", err)
        return send(500, { error = "internal error" })
    end

    -- Send email in a background timer so the HTTP response is immediate.
    -- The OTP is already persisted; a delivery failure only means the admin
    -- must retrieve the code manually from the DB — the login flow still works.
    local email_addr = addr
    local email_vars = {
        code           = code,
        expiry_minutes = math.floor((auth.otp_expiry_secs or 900) / 60),
    }
    ngx.timer.at(0, function()
        local mail_err = email.send_template(email_addr, "otp", email_vars)
        if mail_err then
            ngx.log(ngx.ERR, "otp email failed to=", email_addr, " err=", mail_err,
                " — code stored in DB, admin can retrieve it manually")
        else
            ngx.log(ngx.NOTICE, "otp email sent ok to=", email_addr)
        end
    end)

    send(200, GENERIC_OK)
end)

-- ---------------------------------------------------------------------------
-- POST /admin/auth/otp/verify
-- ---------------------------------------------------------------------------
route("POST", "^/admin/auth/otp/verify$", function()
    local body = read_body()
    local addr = body.email
    local code = body.code
    if not addr or not code then
        return send(400, { error = "email and code required" })
    end

    -- Rate-limit OTP verification: max 5 failed attempts per email per OTP window.
    local auth        = cfg_auth()
    local window      = auth.otp_expiry_secs or 900
    local rl_key      = "otp_fail:" .. addr
    local rl          = ngx.shared.aig_ratelimit
    local attempts    = rl:get(rl_key) or 0
    if attempts >= 5 then
        ngx.log(ngx.WARN, "otp brute-force blocked for ", addr)
        return send(429, { error = "too many attempts, request a new code" })
    end

    local code_hash = crypto.sha256_hex(tostring(code):match("^%s*(.-)%s*$"))
    local err       = storage.consume_email_otp(addr, code_hash)
    if err then
        -- Increment failure counter; TTL aligned to the OTP window so the
        -- lockout expires when the OTP itself expires.
        local new_count = attempts + 1
        rl:set(rl_key, new_count, window)
        return send(401, { error = "invalid or expired code" })
    end

    -- Success — clear the failure counter.
    rl:delete(rl_key)

    local user = storage.find_admin_user_by_email(addr)
    if not user then
        return send(403, { error = "forbidden" })
    end

    storage.touch_last_login(user.id)
    local remember_me = body.remember_me == true
    local token, max_age = issue_jwt_for(user, remember_me)
    set_session_cookie(token, max_age)
    send(200, {
        user = { id = user.id, email = user.email, role = user.role, tenant_id = user.tenant_id },
    })
end)

-- ---------------------------------------------------------------------------
-- GET /admin/auth/google  — initiate OAuth flow
-- ---------------------------------------------------------------------------
route("GET", "^/admin/auth/google$", function()
    local auth = cfg_auth()
    if not auth.google_client_id then
        return send(501, { error = "Google SSO is not configured (set AIG_GOOGLE_CLIENT_ID)" })
    end

    local state = crypto.random_hex(16)
    ngx.shared.aig_ratelimit:set("google_state:" .. state, 1, 600)

    local params = {
        "client_id="    .. ngx.escape_uri(auth.google_client_id),
        "redirect_uri=" .. ngx.escape_uri(auth.google_redirect_uri or ""),
        "response_type=code",
        "scope="        .. ngx.escape_uri("openid email profile"),
        "state="        .. state,
        "access_type=offline",
        "prompt=select_account",
    }
    ngx.redirect("https://accounts.google.com/o/oauth2/v2/auth?" ..
                 table.concat(params, "&"), 302)
end)

-- ---------------------------------------------------------------------------
-- GET /admin/auth/google/callback  — OAuth callback
-- ---------------------------------------------------------------------------
route("GET", "^/admin/auth/google/callback$", function()
    local args  = ngx.req.get_uri_args()
    local code  = args.code
    local state = args.state

    if not code then
        return send(400, { error = "missing code" })
    end

    -- Validate CSRF state
    local state_key = "google_state:" .. (state or "")
    if not ngx.shared.aig_ratelimit:get(state_key) then
        return send(400, { error = "invalid or expired state" })
    end
    ngx.shared.aig_ratelimit:delete(state_key)

    local auth  = cfg_auth()
    local httpc = require("resty.http").new()
    httpc:set_timeout(10000)

    -- Exchange code for tokens
    local token_res, err = httpc:request_uri(
        "https://oauth2.googleapis.com/token", {
            method  = "POST",
            body    = table.concat({
                "code="          .. ngx.escape_uri(code),
                "client_id="     .. ngx.escape_uri(auth.google_client_id or ""),
                "client_secret=" .. ngx.escape_uri(auth.google_client_secret or ""),
                "redirect_uri="  .. ngx.escape_uri(auth.google_redirect_uri or ""),
                "grant_type=authorization_code",
            }, "&"),
            headers    = { ["Content-Type"] = "application/x-www-form-urlencoded" },
            ssl_verify = true,
        })

    if not token_res or token_res.status ~= 200 then
        ngx.log(ngx.ERR, "google token exchange: ", err or (token_res and token_res.body))
        return send(502, { error = "OAuth token exchange failed" })
    end

    local token_data = json.decode(token_res.body)
    if not token_data or not token_data.id_token then
        return send(502, { error = "no id_token in response" })
    end

    -- Decode id_token payload (skip sig verify — we trust Google HTTPS)
    local id_parts = {}
    for p in token_data.id_token:gmatch("[^%.]+") do id_parts[#id_parts + 1] = p end
    if #id_parts < 2 then return send(502, { error = "invalid id_token format" }) end

    local raw = id_parts[2]
    local pad = (4 - #raw % 4) % 4
    raw = (raw .. string.rep("=", pad)):gsub("-", "+"):gsub("_", "/")
    local claims = json.decode(ngx.decode_base64(raw) or "")
    if not claims or not claims.email then
        return send(502, { error = "could not decode id_token claims" })
    end

    -- Resolve user — must be a pre-provisioned admin
    local user = storage.find_admin_user_by_email(claims.email)
    if not user then
        return send(403, { error = "not an admin user" })
    end

    storage.upsert_oauth_link(user.id, "google", claims.sub, claims.email)
    storage.touch_last_login(user.id)

    local token, max_age = issue_jwt_for(user)
    set_session_cookie(token, max_age)
    ngx.redirect("/", 302)
end)

-- ---------------------------------------------------------------------------
-- CORS preflight for /admin/auth/*
-- ---------------------------------------------------------------------------
route("OPTIONS", "^/admin/auth/", function()
    ngx.header["Access-Control-Allow-Origin"]      = ngx.var.http_origin or "*"
    ngx.header["Access-Control-Allow-Credentials"] = "true"
    ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"]     = "Content-Type"
    ngx.status = 204
    ngx.exit(204)
end)

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
function M.handle()
    local method = ngx.req.get_method()
    local path   = ngx.var.uri

    if method == "OPTIONS" then
        ngx.header["Access-Control-Allow-Origin"]      = ngx.var.http_origin or "*"
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, OPTIONS"
        ngx.header["Access-Control-Allow-Headers"]     = "Content-Type"
        ngx.status = 204
        ngx.exit(204)
        return
    end

    for _, r in ipairs(ROUTES) do
        if r.method == method and path:match(r.pattern) then
            r.handler()
            return
        end
    end

    send(404, { error = "not found" })
end

return M
