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

    -- GET /admin/v1/conversations?limit=50&offset=0&archived=1
    route("GET", "^/admin/v1/conversations$", function()
        local u    = ngx.ctx.admin_user
        local args = ngx.req.get_uri_args()
        local rows = storage.list_conversations(u.id, tonumber(args.limit), tonumber(args.offset),
                         { archived = args.archived == "1" })
        send(200, rows)
    end)

    -- POST /admin/v1/conversations  { gateway_id, title?, model?, system_prompt?, temperature?, max_tokens?, source_share_token? }
    route("POST", "^/admin/v1/conversations$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()

        -- Fork from a share token
        if body.source_share_token then
            local share = storage.get_share_by_token(body.source_share_token)
            if not share then return send(404, { error = "share not found" }) end
            local snapshot = json.decode(share.snapshot_json)
            if not snapshot then return send(500, { error = "invalid snapshot" }) end
            if not body.gateway_id or body.gateway_id == "" then
                return send(400, { error = "gateway_id is required" })
            end
            local new_id, err = storage.create_conversation({
                user_id   = u.id,
                gateway_id = body.gateway_id,
                title     = snapshot.title or "Shared conversation",
                model     = "",
            })
            if not new_id then return send(500, { error = tostring(err) }) end
            local base_time = math.floor(ngx.now())
            for i, m in ipairs(snapshot.messages or {}) do
                storage.append_message({
                    conversation_id  = new_id,
                    role             = m.role,
                    content          = m.content,
                    gateway_id       = m.gateway_id,
                    model            = m.model,
                    created_at       = base_time + i,
                })
            end
            local conv, e2 = storage.get_conversation(new_id, u.id)
            if not conv then return send(500, { error = tostring(e2) }) end
            return send(201, conv)
        end

        if not body.gateway_id or body.gateway_id == "" then
            return send(400, { error = "gateway_id is required" })
        end
        local id, err = storage.create_conversation({
            user_id       = u.id,
            gateway_id    = body.gateway_id,
            project_id    = nullable(body.project_id),
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

    -- PATCH /admin/v1/conversations/:id  { title?, model?, system_prompt?, temperature?, max_tokens?, gateway_id?, starred?, archived_at?, memory_disabled? }
    route("PATCH", "^/admin/v1/conversations/([^/]+)$", function(id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        local data = {}
        if body.title           ~= nil then data.title           = nullable(body.title) end
        if body.model           ~= nil then data.model           = nullable(body.model) end
        if body.system_prompt   ~= nil then data.system_prompt   = nullable(body.system_prompt) end
        if body.temperature     ~= nil then data.temperature     = nullable(body.temperature) end
        if body.max_tokens      ~= nil then data.max_tokens      = nullable(body.max_tokens) end
        if body.gateway_id      ~= nil then data.gateway_id      = nullable(body.gateway_id) end
        if body.starred         ~= nil then data.starred         = (tonumber(body.starred) == 0) and 0 or 1 end
        if body.memory_disabled ~= nil then data.memory_disabled = (tonumber(body.memory_disabled) == 0) and 0 or 1 end
        if body.archived_at     ~= nil then data.archived_at     = (body.archived_at == json.null) and ngx.null or body.archived_at end
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

    -- ── Share links ───────────────────────────────────────────────────────────

    -- POST /admin/v1/conversations/:id/share — create/refresh share link
    route("POST", "^/admin/v1/conversations/([^/]+)/share$", function(id)
        local u = ngx.ctx.admin_user
        local conv, err = storage.get_conversation(id, u.id)
        if not conv then
            return send(err == "not_found" and 404 or 500, { error = tostring(err) })
        end
        -- Build snapshot: strip system_prompt and per-message cost/token fields
        local snapshot_msgs = {}
        for _, m in ipairs(conv.messages or {}) do
            if m.role ~= "system" then
                snapshot_msgs[#snapshot_msgs + 1] = {
                    id         = m.id,
                    role       = m.role,
                    content    = m.content,
                    gateway_id = m.gateway_id,
                    model      = m.model,
                    created_at = m.created_at,
                    attachments = m.attachments or {},
                }
            end
        end
        local snapshot = json.encode({
            title    = conv.title,
            messages = snapshot_msgs,
        })
        local token = ngx.md5(id .. u.id .. tostring(ngx.now())):lower()
        local ok, e2 = storage.upsert_share(id, u.id, token, snapshot)
        if not ok then return send(500, { error = tostring(e2) }) end
        local base = os.getenv("AIG_SHARE_BASE_URL") or (ngx.var.scheme .. "://" .. (ngx.var.http_host or "localhost"))
        send(201, { token = token, url = base .. "/shared/" .. token })
    end)

    -- DELETE /admin/v1/conversations/:id/share — revoke share link
    route("DELETE", "^/admin/v1/conversations/([^/]+)/share$", function(id)
        local u = ngx.ctx.admin_user
        storage.delete_share(id, u.id)
        send(200, { ok = true })
    end)

    -- GET /admin/v1/conversations/:id/share — get existing share token if any
    route("GET", "^/admin/v1/conversations/([^/]+)/share$", function(id)
        local u   = ngx.ctx.admin_user
        local row = storage.get_share_by_conv(id, u.id)
        if not row then return send(404, { error = "not_shared" }) end
        local base = os.getenv("AIG_SHARE_BASE_URL") or (ngx.var.scheme .. "://" .. (ngx.var.http_host or "localhost"))
        send(200, { token = row.token, url = base .. "/shared/" .. row.token })
    end)

    route("GET", "^/admin/v1/conversations/([^/]+)/feedback$", function(conv_id)
        local u  = ngx.ctx.admin_user
        local fb = storage.get_feedback(conv_id, u.id)
        if not fb then return send(404, { error = "not_found" }) end
        send(200, fb)
    end)

    route("PUT", "^/admin/v1/conversations/([^/]+)/feedback$", function(conv_id)
        local u      = ngx.ctx.admin_user
        local body   = read_body()
        local rating = tonumber(body.rating)
        if not rating or rating < 1 or rating > 5 then
            return send(400, { error = "rating must be 1-5" })
        end
        local _, err = storage.upsert_feedback({
            conversation_id = conv_id,
            user_id         = u.id,
            rating          = rating,
            comment         = body.comment or "",
        })
        if err then return send(500, { error = err }) end
        send(200, { ok = true })
    end)

    -- ── Messages ────────────────────────────────────────────────────────────

    -- POST /admin/v1/conversations/:id/messages  { role, content, input_tokens?, output_tokens?, cost_usd?, latency_ms?, gateway_id? }
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
            gateway_id        = nullable(body.gateway_id),
            model             = nullable(body.model),
            created_at        = tonumber(body.created_at) or nil,
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

    -- ── Slash commands ────────────────────────────────────────────────────────

    -- GET /admin/v1/chat-commands
    route("GET", "^/admin/v1/chat%-commands$", function()
        local u = ngx.ctx.admin_user
        send(200, storage.list_commands(u.id))
    end)

    -- POST /admin/v1/chat-commands  { name, description?, template }
    route("POST", "^/admin/v1/chat%-commands$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.name or body.name == "" then
            return send(400, { error = "name is required" })
        end
        if not body.template or body.template == "" then
            return send(400, { error = "template is required" })
        end
        local id, err = storage.create_command({
            user_id     = u.id,
            name        = body.name,
            description = body.description or "",
            template    = body.template,
        })
        if not id then return send(500, { error = tostring(err) }) end
        send(201, { id = id })
    end)

    -- PATCH /admin/v1/chat-commands/:id
    route("PATCH", "^/admin/v1/chat%-commands/([^/]+)$", function(id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        local data = {}
        if body.name        ~= nil then data.name        = nullable(body.name) end
        if body.description ~= nil then data.description = nullable(body.description) end
        if body.template    ~= nil then data.template    = nullable(body.template) end
        local err = storage.update_command(id, u.id, data)
        if err then return send(500, { error = tostring(err) }) end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/chat-commands/:id
    route("DELETE", "^/admin/v1/chat%-commands/([^/]+)$", function(id)
        local u = ngx.ctx.admin_user
        storage.delete_command(id, u.id)
        send(200, { ok = true })
    end)

    -- ── Document file processor ───────────────────────────────────────────────
    -- POST /admin/v1/chat/files  { gateway_id, filename, mime_type, data, [extract_text] }
    -- For .docx files: extracts plain text from the Word document on the server
    -- and returns { text: "..." } so the frontend can include it as a text block.
    -- For PDF + extract_text=true: text-based pages extracted directly via fitz (fast path);
    --   scanned pages rendered at 300 DPI, contrast-enhanced, then processed by MinerU.
    --   Returns { text: "..." }.
    -- For PDF/text (Anthropic path): uploads to Anthropic Files API and returns { file_id: "..." }.
    route("POST", "^/admin/v1/chat/files$", function()
        local body = read_body()
        if not body.data or body.data == "" then
            return send(400, { error = "data is required" })
        end
        if not body.filename or body.filename == "" then
            return send(400, { error = "filename is required" })
        end
        local mime = body.mime_type or "application/octet-stream"

        local bin = ngx.decode_base64(body.data)
        if not bin then
            return send(400, { error = "data is not valid base64" })
        end

        -- .docx: extract text server-side (Anthropic does not accept docx as a document block)
        if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" then
            -- Write to a temp file, run python3 to extract text, clean up
            local tmpfile = "/tmp/aig_docx_" .. ngx.now() .. "_" .. math.random(100000) .. ".docx"
            local f = io.open(tmpfile, "wb")
            if not f then
                return send(500, { error = "Failed to create temp file for docx extraction" })
            end
            f:write(bin)
            f:close()

            -- Write a Python helper script to /tmp and run it (avoids shell quoting issues)
            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, re
try:
    z = zipfile.ZipFile(sys.argv[1])
    xml = z.read('word/document.xml').decode('utf-8', 'replace')
    txt = re.sub(r'<[^>]+>', '', xml)
    txt = re.sub(r'[ \t]+', ' ', txt)
    txt = re.sub(r'\n{3,}', '\n\n', txt.strip())
    print(txt)
except Exception as e:
    sys.exit(1)
]])
                sf:close()
            end
            local cmd = "python3 " .. script .. " " .. tmpfile .. " 2>/dev/null"
            local pipe = io.popen(cmd, "r")
            local text = pipe and pipe:read("*a") or ""
            if pipe then pipe:close() end
            os.remove(tmpfile)
            os.remove(script)

            text = text:gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then
                return send(422, { error = "Could not extract text from .docx file" })
            end
            return send(200, { text = text })
        end

        -- .ods: convert to CSV server-side (stdlib only), then upload CSV to Files API
        if mime == "application/vnd.oasis.opendocument.spreadsheet" then
            local tmpfile = "/tmp/aig_ods_" .. ngx.now() .. "_" .. math.random(100000) .. ".ods"
            local f = io.open(tmpfile, "wb")
            if not f then
                return send(500, { error = "Failed to create temp file for ODS conversion" })
            end
            f:write(bin)
            f:close()

            local csvfile = tmpfile .. ".csv"
            local script  = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, csv, io
import xml.etree.ElementTree as ET
NS = {'t': 'urn:oasis:names:tc:opendocument:xmlns:table:1.0',
      'o': 'urn:oasis:names:tc:opendocument:xmlns:office:1.0',
      'tx': 'urn:oasis:names:tc:opendocument:xmlns:text:1.0',
      'v': 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'}
try:
    z = zipfile.ZipFile(sys.argv[1])
    root = ET.fromstring(z.read('content.xml'))
    out = io.open(sys.argv[2], 'w', newline='', encoding='utf-8')
    w = csv.writer(out)
    for sheet in root.findall('.//t:table', NS):
        for row in sheet.findall('t:table-row', NS):
            cells = []
            for cell in row.findall('t:table-cell', NS):
                repeat_n = int(cell.get('{urn:oasis:names:tc:opendocument:xmlns:table:1.0}number-columns-repeated') or 1)
                parts = [p.text or '' for p in cell.findall('.//tx:p', NS)]
                val = ' '.join(parts)
                cells.extend([val] * repeat_n)
            # trim trailing empty cells
            while cells and cells[-1] == '':
                cells.pop()
            if cells:
                w.writerow(cells)
    out.close()
except Exception as e:
    sys.exit(1)
]])
                sf:close()
            end
            local cmd = "python3 " .. script .. " " .. tmpfile .. " " .. csvfile .. " 2>/dev/null"
            os.execute(cmd)
            os.remove(tmpfile)
            os.remove(script)

            local cf = io.open(csvfile, "rb")
            local csv_data = cf and cf:read("*a") or ""
            if cf then cf:close() end
            os.remove(csvfile)

            csv_data = csv_data:gsub("^%s+", ""):gsub("%s+$", "")
            if csv_data == "" then
                return send(422, { error = "Could not convert .ods to CSV" })
            end

            -- Replace bin/mime so the Files API upload below sends the CSV as plain text
            -- (Anthropic Files API only accepts PDF and text/plain for document blocks)
            bin  = csv_data
            mime = "text/plain"
            body.filename = body.filename:gsub("%.ods$", ".csv")
        end

        -- .xlsx / .xlsm: extract sheet data as CSV text, then upload as text/plain
        if mime == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        or mime == "application/vnd.ms-excel.sheet.macroenabled.12" then
            local tmpfile = "/tmp/aig_xlsx_" .. ngx.now() .. "_" .. math.random(100000) .. ".xlsx"
            local f = io.open(tmpfile, "wb")
            if not f then
                return send(500, { error = "Failed to create temp file for xlsx conversion" })
            end
            f:write(bin)
            f:close()

            local csvfile = tmpfile .. ".csv"
            local script  = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, csv, io, re
import xml.etree.ElementTree as ET
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def col_index(ref):
    col = re.sub(r'\d+', '', ref)
    result = 0
    for c in col:
        result = result * 26 + (ord(c.upper()) - ord('A') + 1)
    return result - 1
try:
    xlsx_path, out_path = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(xlsx_path) as z:
        names = z.namelist()
        shared = []
        if 'xl/sharedStrings.xml' in names:
            root = ET.fromstring(z.read('xl/sharedStrings.xml'))
            for si in root.findall('{' + NS + '}si'):
                parts = [t.text or '' for t in si.iter('{' + NS + '}t')]
                shared.append(''.join(parts))
        sheets = sorted([n for n in names if re.match(r'xl/worksheets/sheet\d+\.xml', n)])
        with io.open(out_path, 'w', newline='', encoding='utf-8') as fout:
            w = csv.writer(fout)
            for sp in sheets:
                root = ET.fromstring(z.read(sp))
                for row in root.findall('.//{' + NS + '}row'):
                    cmap = {}
                    for cell in row.findall('{' + NS + '}c'):
                        r = cell.get('r', '')
                        col = col_index(r) if r else len(cmap)
                        t = cell.get('t', '')
                        v_el = cell.find('{' + NS + '}v')
                        val = ''
                        if t == 's' and v_el is not None:
                            idx = int(v_el.text or 0)
                            val = shared[idx] if 0 <= idx < len(shared) else ''
                        elif t == 'inlineStr':
                            is_el = cell.find('.//{' + NS + '}t')
                            val = (is_el.text or '') if is_el is not None else ''
                        elif v_el is not None:
                            val = v_el.text or ''
                        cmap[col] = val
                    if cmap:
                        mx = max(cmap.keys())
                        rd = [cmap.get(i, '') for i in range(mx + 1)]
                        while rd and rd[-1] == '':
                            rd.pop()
                        if rd:
                            w.writerow(rd)
except Exception:
    sys.exit(1)
]])
                sf:close()
            end
            local cmd = "python3 " .. script .. " " .. tmpfile .. " " .. csvfile .. " 2>/dev/null"
            os.execute(cmd)
            os.remove(tmpfile)
            os.remove(script)

            local cf = io.open(csvfile, "rb")
            local csv_data = cf and cf:read("*a") or ""
            if cf then cf:close() end
            os.remove(csvfile)

            csv_data = csv_data:gsub("^%s+", ""):gsub("%s+$", "")
            if csv_data == "" then
                return send(422, { error = "Could not convert .xlsx to CSV" })
            end

            bin  = csv_data
            mime = "text/plain"
            body.filename = body.filename:gsub("%.xlsx?$", ".csv"):gsub("%.xlsm$", ".csv")
        end

        -- CSV/TSV uploaded directly: Anthropic only accepts text/plain for document blocks
        if mime == "text/csv" or mime == "text/tab-separated-values" then
            mime = "text/plain"
        end

        -- Image via MinerU: send directly (no rasterization needed).
        -- Triggered when extract_text=true for non-vision-capable vLLM models.
        if mime:match("^image/") and body.extract_text then
            local ext = mime:match("^image/(.+)$") or "png"
            local tmpfile = "/tmp/aig_img_" .. math.floor(ngx.now()) .. "_" .. math.random(100000) .. "." .. ext
            local f = io.open(tmpfile, "wb")
            if not f then
                return send(500, { error = "Failed to create temp file for image extraction" })
            end
            f:write(bin)
            f:close()

            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, base64, json
from urllib.request import urlopen, Request

MINERU_URL = "http://172.28.0.1:8084/v1/chat/completions"

imgfile, mime_type = sys.argv[1], sys.argv[2]
with open(imgfile, "rb") as fh:
    b64 = base64.b64encode(fh.read()).decode()

payload = json.dumps({
    "model": "mineru2",
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": "data:" + mime_type + ";base64," + b64}},
        {"type": "text", "text": "Describe this image in detail, extracting all visible text, data, and content."}
    ]}],
    "max_tokens": 2048
}).encode()
req = Request(MINERU_URL, data=payload, headers={"Content-Type": "application/json"})
try:
    with urlopen(req, timeout=120) as r:
        data = json.loads(r.read())
    print(data["choices"][0]["message"]["content"])
except Exception as e:
    print("ERROR:" + str(e), file=sys.stderr)
    sys.exit(1)
]])
                sf:close()
            end

            local cmd = "python3 " .. script .. " " .. tmpfile .. " " .. mime .. " 2>/dev/null"
            local pipe = io.popen(cmd, "r")
            local text = pipe and pipe:read("*a") or ""
            if pipe then pipe:close() end
            os.remove(tmpfile)
            os.remove(script)

            text = text:gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then
                return send(422, { error = "MinerU could not describe the image" })
            end
            return send(200, { text = text })
        end

        -- PDF via MinerU: render each page to PNG and convert to Markdown.
        -- Triggered when extract_text=true (sent by non-Anthropic model paths).
        if mime == "application/pdf" and body.extract_text then
            local tmpfile = "/tmp/aig_pdf_" .. math.floor(ngx.now()) .. "_" .. math.random(100000) .. ".pdf"
            local f = io.open(tmpfile, "wb")
            if not f then
                return send(500, { error = "Failed to create temp file for PDF extraction" })
            end
            f:write(bin)
            f:close()

            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, base64, json, io, fitz
from urllib.request import urlopen, Request
from PIL import Image, ImageEnhance, ImageFilter

MINERU_URL    = "http://172.28.0.1:8084/v1/chat/completions"
MAX_PAGES     = 20
TEXT_THRESHOLD = 50   # chars/page — below this we treat the page as a scan
STRIPS        = 2     # horizontal strips per scanned page (halves keeps ~1392 prompt tokens)
FOOTER_RATIO  = 0.91  # blocks below this fraction of page height = company letterhead

def extract_page_text(page):
    """Spatially-aware text extraction with footer labeling.

    sort=True orders blocks geometrically so multi-column layouts (form labels
    next to their filled values) are interleaved correctly.  Blocks in the
    bottom 9% of the page are tagged [Briefkopf/Letterhead] so the LLM does not
    confuse the company IBAN printed there with form fields belonging to the
    Verkäufer.
    """
    footer_y = page.rect.height * FOOTER_RATIO
    blocks = page.get_text("blocks", sort=True)
    main_parts, footer_parts = [], []
    for b in blocks:
        _x0, y0, _x1, _y1, text = b[0], b[1], b[2], b[3], b[4]
        txt = text.strip()
        if not txt:
            continue
        if y0 >= footer_y:
            footer_parts.append(txt)
        else:
            main_parts.append(txt)
    result = "\n".join(main_parts)
    if footer_parts:
        result += "\n\n[Briefkopf/Letterhead]\n" + "\n".join(footer_parts)
    return result

def enhance_scan(pil_img):
    """Greyscale + contrast boost + sharpen for a scanned strip."""
    img = pil_img.convert("L")
    img = ImageEnhance.Contrast(img).enhance(1.8)
    img = img.filter(ImageFilter.SHARPEN)
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()

def call_mineru(png_bytes):
    b64 = base64.b64encode(png_bytes).decode()
    payload = json.dumps({
        "model": "mineru2",
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
            {"type": "text", "text": "Convert this document page to markdown."}
        ]}],
        "max_tokens": 2048
    }).encode()
    req = Request(MINERU_URL, data=payload, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=120) as r:
        data = json.loads(r.read())
    return data["choices"][0]["message"]["content"]

try:
    doc = fitz.open(sys.argv[1])
    pages_md = []
    for i, page in enumerate(doc):
        if i >= MAX_PAGES:
            break
        # Fast path: digital PDF with extractable text
        text = extract_page_text(page)
        if len(text) >= TEXT_THRESHOLD:
            pages_md.append(text)
            continue
        # Scanned page: render at 150 DPI and process in horizontal strips.
        # Sending the full page saturates MinerU's ~2042 prompt-token limit,
        # leaving almost no budget for generation. Halves (~1392 tokens each)
        # produce dramatically more output.
        pix = page.get_pixmap(dpi=150)
        img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
        strip_h = img.height // STRIPS
        strip_parts = []
        for s in range(STRIPS):
            y0 = s * strip_h
            y1 = img.height if s == STRIPS - 1 else y0 + strip_h
            strip = img.crop((0, y0, img.width, y1))
            md = call_mineru(enhance_scan(strip))
            if md.strip():
                strip_parts.append(md)
        pages_md.append("\n".join(strip_parts))
    print("\n\n---\n\n".join(pages_md))
except Exception as e:
    print("ERROR:" + str(e), file=sys.stderr)
    sys.exit(1)
]])
                sf:close()
            end

            local cmd = "python3 " .. script .. " " .. tmpfile .. " 2>/dev/null"
            local pipe = io.popen(cmd, "r")
            local text = pipe and pipe:read("*a") or ""
            if pipe then pipe:close() end
            os.remove(tmpfile)
            os.remove(script)

            text = text:gsub("^%s+", ""):gsub("%s+$", "")
            if text == "" then
                return send(422, { error = "MinerU could not extract text from PDF" })
            end
            return send(200, { text = text })
        end

        -- PDF / plain text / spreadsheets (converted above): upload to Anthropic Files API
        if not body.gateway_id or body.gateway_id == "" then
            return send(400, { error = "gateway_id is required for PDF/text uploads" })
        end

        local api_key, key_err = byok.get_key(body.gateway_id, "anthropic", "default")
        if not api_key then
            return send(503, { error = "Anthropic key not configured for this gateway: " .. tostring(key_err) })
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
                ["x-api-key"]         = api_key,
                ["anthropic-version"] = "2023-06-01",
                ["anthropic-beta"]    = "files-api-2025-04-14",
                ["Content-Type"]      = "multipart/form-data; boundary=" .. boundary,
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

    -- ── PDF export ────────────────────────────────────────────────────────────
    -- POST /admin/v1/chat/export-pdf  { markdown, filename? }
    -- Converts a markdown chat transcript to PDF via pandoc + weasyprint.
    route("POST", "^/admin/v1/chat/export%-pdf$", function()
        local body = read_body()
        if not body.markdown or body.markdown == "" then
            return send(400, { error = "markdown is required" })
        end

        local rand   = math.random(100000)
        local prefix = "/tmp/aig_pdf_" .. math.floor(ngx.now()) .. "_" .. rand
        local tmpmd  = prefix .. ".md"
        local tmpcss = prefix .. ".css"
        local tmppdf = prefix .. ".pdf"

        -- Write markdown
        local mf = io.open(tmpmd, "w")
        if not mf then return send(500, { error = "Failed to write temp markdown file" }) end
        mf:write(body.markdown)
        mf:close()

        -- Write embedded CSS for clean chat-transcript formatting
        local css = [[
body { font-family: "Liberation Serif", "Noto Color Emoji", Georgia, serif; font-size: 11pt; line-height: 1.65; color: #1a1a1a; max-width: 48em; margin: 0 auto; padding: 2em 1em; }
h1 { font-size: 18pt; border-bottom: 2px solid #333; padding-bottom: 6pt; margin-bottom: 4pt; }
em { color: #555; }
hr { border: none; border-top: 1px solid #ccc; margin: 14pt 0; }
p strong:only-child { font-size: 10.5pt; text-transform: uppercase; letter-spacing: 0.05em; color: #444; }
pre { background: #f5f5f5; border-left: 3px solid #ccc; padding: 10pt 12pt; font-size: 9.5pt; white-space: pre-wrap; word-break: break-word; }
code { font-family: "Liberation Mono", "Noto Color Emoji", "Courier New", monospace; font-size: 9.5pt; background: #f5f5f5; padding: 1pt 3pt; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; width: 100%; font-size: 10pt; }
th, td { border: 1px solid #ccc; padding: 4pt 8pt; text-align: left; }
th { background: #f0f0f0; font-weight: bold; }
blockquote { border-left: 3px solid #aaa; margin: 0 0 0 1em; padding-left: 1em; color: #555; }
a { color: #1a6fb5; }
]]
        local cf = io.open(tmpcss, "w")
        if not cf then
            os.remove(tmpmd)
            return send(500, { error = "Failed to write temp CSS file" })
        end
        cf:write(css)
        cf:close()

        -- Run pandoc → weasyprint (cd /tmp so pandoc's own temp files land there;
        -- use full path to weasyprint since nginx worker may have a minimal PATH)
        local cmd = string.format(
            "cd /tmp && pandoc --pdf-engine=/usr/local/bin/weasyprint --standalone --metadata title='Chat Export' --css=%s -o %s %s 2>&1",
            tmpcss, tmppdf, tmpmd
        )
        local pipe    = io.popen(cmd, "r")
        local out     = pipe and pipe:read("*a") or ""
        local ok_pipe = pipe and pipe:close()
        os.remove(tmpmd)
        os.remove(tmpcss)

        local pf = io.open(tmppdf, "rb")
        if not pf then
            return send(500, { error = "PDF generation failed: " .. (out or "") })
        end
        local pdf_data = pf:read("*a")
        pf:close()
        os.remove(tmppdf)

        local dl_name = (body.filename or "conversation") .. ".pdf"
        ngx.header["Access-Control-Allow-Origin"]      = cors_origin()
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.header["Content-Type"]        = "application/pdf"
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. dl_name .. '"'
        ngx.header["Content-Length"]      = #pdf_data
        ngx.status = 200
        ngx.print(pdf_data)
        ngx.exit(200)
    end)

    -- ── Memories ───────────────────────────────────────────────────────────────

    -- GET /admin/v1/memories — list all memories for current user
    route("GET", "^/admin/v1/memories$", function()
        local u = ngx.ctx.admin_user
        send(200, storage.list_memories(u.id))
    end)

    -- POST /admin/v1/memories — create a memory  { content, type?, source? }
    route("POST", "^/admin/v1/memories$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.content or body.content == "" then
            return send(400, { error = "content is required" })
        end
        local valid_types   = { fact = true, preference = true, instruction = true }
        local valid_sources = { manual = true, auto = true }
        local mtype  = body.type   or "fact"
        local msource = body.source or "manual"
        if not valid_types[mtype]   then return send(400, { error = "invalid type" }) end
        if not valid_sources[msource] then return send(400, { error = "invalid source" }) end
        local id, err = storage.create_memory({
            user_id = u.id,
            content = body.content,
            type    = mtype,
            source  = msource,
        })
        if not id then return send(500, { error = tostring(err) }) end
        -- Return the full memory object
        local mems = storage.list_memories(u.id)
        for _, m in ipairs(mems) do
            if m.id == id then return send(201, m) end
        end
        send(201, { id = id, content = body.content, type = mtype, source = msource })
    end)

    -- PATCH /admin/v1/memories/:id — update memory content  { content }
    route("PATCH", "^/admin/v1/memories/([^/]+)$", function(id)
        local u    = ngx.ctx.admin_user
        local body = read_body()
        if not body.content or body.content == "" then
            return send(400, { error = "content is required" })
        end
        local err = storage.update_memory(id, u.id, body.content)
        if err then return send(500, { error = tostring(err) }) end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/memories/:id — delete a memory
    route("DELETE", "^/admin/v1/memories/([^/]+)$", function(id)
        local u = ngx.ctx.admin_user
        storage.delete_memory(id, u.id)
        send(200, { ok = true })
    end)

end

return M
