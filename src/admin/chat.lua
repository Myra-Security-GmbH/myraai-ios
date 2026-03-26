-- admin/chat.lua — Chat conversation, message, attachment and preset API routes
-- Routes are registered by calling M.register(route_fn) from admin/api.lua.
-- All routes require an authenticated session (ngx.ctx.admin_user must be set).
--
-- Conversations:
--   GET    /admin/v1/conversations
--   POST   /admin/v1/conversations
--   GET    /admin/v1/conversations/:id
--   PATCH  /admin/v1/conversations/:id
--   DELETE /admin/v1/conversations/:id
-- Messages:
--   POST   /admin/v1/conversations/:id/messages
--   PATCH  /admin/v1/conversations/:id/messages/:mid
--   DELETE /admin/v1/conversations/:id/messages/:mid
-- Attachments:
--   POST   /admin/v1/conversations/:cid/attachments
--   GET    /admin/v1/attachments/:aid
--   DELETE /admin/v1/attachments/:aid
-- Presets:
--   GET    /admin/v1/chat-presets
--   POST   /admin/v1/chat-presets
--   PATCH  /admin/v1/chat-presets/:id
--   DELETE /admin/v1/chat-presets/:id

local json      = require("utils.json")
local storage   = require("storage")
local byok      = require("auth.byok")
local http_util = require("utils.http")

local M = {}

local CORS_ORIGIN = os.getenv("AIG_ADMIN_CORS_ORIGIN")
local function cors_origin()
    return CORS_ORIGIN or ngx.var.http_origin or "*"
end

local function send(status, body)
    ngx.status = status
    ngx.header["Content-Type"]                     = "application/json"
    ngx.header["Access-Control-Allow-Origin"]      = cors_origin()
    ngx.header["Access-Control-Allow-Credentials"] = "true"
    ngx.header["Access-Control-Allow-Headers"]     = "Content-Type, Authorization, x-aig-token"
    ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, PATCH, DELETE, OPTIONS"
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
    return json.decode(raw or "{}")
end

local function nullable(v)
    if v == json.null then return nil end
    return v
end

function M.register(route)

    -- ── Conversations ───────────────────────────────────────────────────────

    -- GET /admin/v1/conversations?limit=50&offset=0
    route("GET", "^/admin/v1/conversations$", function()
        local u    = ngx.ctx.admin_user
        local args = ngx.req.get_uri_args()
        local rows = storage.list_conversations(u.id, tonumber(args.limit), tonumber(args.offset))
        send(200, rows)
    end)

    -- POST /admin/v1/conversations  { gateway_id, title?, model?, system_prompt?, temperature?, max_tokens? }
    route("POST", "^/admin/v1/conversations$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.gateway_id or body.gateway_id == "" then
            return send(400, { error = "gateway_id is required" })
        end
        local id, err = storage.create_conversation({
            user_id       = u.id,
            gateway_id    = body.gateway_id,
            title         = nullable(body.title) or "New conversation",
            model         = nullable(body.model) or "",
            system_prompt = nullable(body.system_prompt),
            temperature   = nullable(body.temperature),
            max_tokens    = nullable(body.max_tokens),
        })
        if not id then return send(500, { error = tostring(err) }) end
        -- Return the full conversation record (empty messages)
        local conv, e2 = storage.get_conversation(id, u.id)
        if not conv then return send(500, { error = tostring(e2) }) end
        send(201, conv)
    end)

    -- GET /admin/v1/conversations/:id
    route("GET", "^/admin/v1/conversations/([^/]+)$", function(id)
        local u = ngx.ctx.admin_user
        local conv, err = storage.get_conversation(id, u.id)
        if not conv then
            return send(err == "not_found" and 404 or 500,
                        { error = tostring(err) })
        end
        send(200, conv)
    end)

    -- PATCH /admin/v1/conversations/:id  { title?, model?, system_prompt?, temperature?, max_tokens?, gateway_id? }
    route("PATCH", "^/admin/v1/conversations/([^/]+)$", function(id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        local data = {}
        if body.title         ~= nil then data.title         = nullable(body.title) end
        if body.model         ~= nil then data.model         = nullable(body.model) end
        if body.system_prompt ~= nil then data.system_prompt = nullable(body.system_prompt) end
        if body.temperature   ~= nil then data.temperature   = nullable(body.temperature) end
        if body.max_tokens    ~= nil then data.max_tokens    = nullable(body.max_tokens) end
        if body.gateway_id    ~= nil then data.gateway_id    = nullable(body.gateway_id) end
        local err = storage.update_conversation(id, u.id, data)
        if err then return send(500, { error = tostring(err) }) end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/conversations/:id
    route("DELETE", "^/admin/v1/conversations/([^/]+)$", function(id)
        local u = ngx.ctx.admin_user
        storage.delete_conversation(id, u.id)
        send(200, { ok = true })
    end)

    -- ── Messages ────────────────────────────────────────────────────────────

    -- POST /admin/v1/conversations/:id/messages  { role, content, input_tokens?, output_tokens?, cost_usd?, latency_ms? }
    route("POST", "^/admin/v1/conversations/([^/]+)/messages$", function(conv_id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.role or not body.content then
            return send(400, { error = "role and content are required" })
        end
        -- Verify conversation ownership
        local conv, cerr = storage.get_conversation(conv_id, u.id)
        if not conv then
            return send(cerr == "not_found" and 404 or 403, { error = "conversation not found" })
        end
        local mid, err = storage.append_message({
            conversation_id   = conv_id,
            parent_message_id = nullable(body.parent_message_id),
            role              = body.role,
            content           = body.content,
            input_tokens      = nullable(body.input_tokens),
            output_tokens     = nullable(body.output_tokens),
            cost_usd          = nullable(body.cost_usd),
            latency_ms        = nullable(body.latency_ms),
        })
        if not mid then return send(500, { error = tostring(err) }) end
        send(201, { id = mid })
    end)

    -- PATCH /admin/v1/conversations/:id/messages/:mid  { content }
    route("PATCH", "^/admin/v1/conversations/([^/]+)/messages/([^/]+)$", function(conv_id, mid)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.content then
            return send(400, { error = "content is required" })
        end
        local err = storage.update_message(mid, conv_id, u.id, body.content)
        if err then return send(500, { error = tostring(err) }) end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/conversations/:id/messages/:mid
    route("DELETE", "^/admin/v1/conversations/([^/]+)/messages/([^/]+)$", function(conv_id, mid)
        local u = ngx.ctx.admin_user
        storage.delete_message(mid, conv_id, u.id)
        send(200, { ok = true })
    end)

    -- ── Attachments ─────────────────────────────────────────────────────────

    -- POST /admin/v1/conversations/:cid/attachments
    -- Body: { message_id, filename, mime_type, data (base64 string) }
    route("POST", "^/admin/v1/conversations/([^/]+)/attachments$", function(conv_id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.message_id or not body.filename or not body.mime_type or not body.data then
            return send(400, { error = "message_id, filename, mime_type, and data are required" })
        end
        -- Ownership: verify conversation belongs to this user
        local conv, cerr = storage.get_conversation(conv_id, u.id)
        if not conv then
            return send(cerr == "not_found" and 404 or 403, { error = "conversation not found" })
        end
        local size = #(body.data or "")
        local aid, err = storage.insert_attachment({
            message_id = body.message_id,
            filename   = body.filename,
            mime_type  = body.mime_type,
            size_bytes = size,
            data       = body.data,
        })
        if not aid then return send(500, { error = tostring(err) }) end
        send(201, {
            id         = aid,
            message_id = body.message_id,
            filename   = body.filename,
            mime_type  = body.mime_type,
            size_bytes = size,
        })
    end)

    -- GET /admin/v1/attachments/:aid  — returns JSON with base64 data field
    route("GET", "^/admin/v1/attachments/([^/]+)$", function(aid)
        local u = ngx.ctx.admin_user
        local att, err = storage.get_attachment(aid, u.id)
        if not att then
            return send(err == "not_found" and 404 or 500, { error = tostring(err) })
        end
        send(200, att)
    end)

    -- DELETE /admin/v1/attachments/:aid
    route("DELETE", "^/admin/v1/attachments/([^/]+)$", function(aid)
        local u = ngx.ctx.admin_user
        storage.delete_attachment(aid, u.id)
        send(200, { ok = true })
    end)

    -- ── Presets ─────────────────────────────────────────────────────────────

    -- GET /admin/v1/chat-presets
    route("GET", "^/admin/v1/chat%-presets$", function()
        local u = ngx.ctx.admin_user
        send(200, storage.list_presets(u.id))
    end)

    -- POST /admin/v1/chat-presets  { name, model?, system_prompt?, temperature?, max_tokens? }
    route("POST", "^/admin/v1/chat%-presets$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.name or body.name == "" then
            return send(400, { error = "name is required" })
        end
        local id, err = storage.create_preset({
            user_id       = u.id,
            name          = body.name,
            model         = nullable(body.model) or "",
            system_prompt = nullable(body.system_prompt),
            temperature   = nullable(body.temperature),
            max_tokens    = nullable(body.max_tokens),
        })
        if not id then return send(500, { error = tostring(err) }) end
        send(201, { id = id })
    end)

    -- PATCH /admin/v1/chat-presets/:id
    route("PATCH", "^/admin/v1/chat%-presets/([^/]+)$", function(id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        local data = {}
        if body.name          ~= nil then data.name          = nullable(body.name) end
        if body.model         ~= nil then data.model         = nullable(body.model) end
        if body.system_prompt ~= nil then data.system_prompt = nullable(body.system_prompt) end
        if body.temperature   ~= nil then data.temperature   = nullable(body.temperature) end
        if body.max_tokens    ~= nil then data.max_tokens    = nullable(body.max_tokens) end
        local err = storage.update_preset(id, u.id, data)
        if err then return send(500, { error = tostring(err) }) end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/chat-presets/:id
    route("DELETE", "^/admin/v1/chat%-presets/([^/]+)$", function(id)
        local u = ngx.ctx.admin_user
        storage.delete_preset(id, u.id)
        send(200, { ok = true })
    end)

    -- ── Anthropic Files API proxy ────────────────────────────────────────────
    -- POST /admin/v1/chat/files  { gateway_id, filename, mime_type, data }
    -- Uploads a file to Anthropic's Files API using the gateway's configured
    -- Anthropic key and returns the resulting file_id.  Only the gateway owner
    -- (or an admin) is allowed to use a given gateway's key.
    route("POST", "^/admin/v1/chat/files$", function()
        local body = read_body()
        if not body.gateway_id or body.gateway_id == "" then
            return send(400, { error = "gateway_id is required" })
        end
        if not body.data or body.data == "" then
            return send(400, { error = "data is required" })
        end
        if not body.filename or body.filename == "" then
            return send(400, { error = "filename is required" })
        end
        local mime = body.mime_type or "application/octet-stream"

        local api_key, key_err = byok.get_key(body.gateway_id, "anthropic", "default")
        if not api_key then
            return send(503, { error = "Anthropic key not configured for this gateway: " .. tostring(key_err) })
        end

        local bin = ngx.decode_base64(body.data)
        if not bin then
            return send(400, { error = "data is not valid base64" })
        end

        local boundary = "----AIG_FILES_BOUNDARY"
        local crlf     = "\r\n"
        local multipart = table.concat({
            "--" .. boundary .. crlf,
            'Content-Disposition: form-data; name="file"; filename="' .. body.filename .. '"' .. crlf,
            "Content-Type: " .. mime .. crlf,
            crlf,
            bin,
            crlf,
            "--" .. boundary .. "--" .. crlf,
        }, "")

        local status, _, resp_body, req_err = http_util.request({
            method  = "POST",
            url     = "https://api.anthropic.com/v1/files",
            headers = {
                ["x-api-key"]        = api_key,
                ["anthropic-version"] = "2023-06-01",
                ["anthropic-beta"]   = "files-api-2025-04-14",
                ["Content-Type"]     = "multipart/form-data; boundary=" .. boundary,
            },
            body    = multipart,
        })

        if req_err then
            return send(502, { error = "Files API request failed: " .. tostring(req_err) })
        end

        local parsed = json.decode(resp_body or "")
        if status ~= 200 then
            local msg = (parsed and parsed.error and parsed.error.message) or resp_body or "unknown error"
            return send(status or 502, { error = "Files API error: " .. tostring(msg) })
        end

        if not parsed or not parsed.id then
            return send(502, { error = "Files API returned unexpected response" })
        end

        send(200, { file_id = parsed.id })
    end)

end

return M
