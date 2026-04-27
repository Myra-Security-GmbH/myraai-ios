-- admin/projects.lua — Projects API routes
local push = require("push")
-- Routes are registered by calling M.register(route_fn) from admin/api.lua.
-- All routes require an authenticated session (ngx.ctx.admin_user must be set).
--
-- Projects:
--   GET    /admin/v1/projects
--   POST   /admin/v1/projects
--   GET    /admin/v1/projects/:id
--   PATCH  /admin/v1/projects/:id
--   DELETE /admin/v1/projects/:id
-- Project members:
--   POST   /admin/v1/projects/:id/members          { user_id, role }
--   PATCH  /admin/v1/projects/:id/members/:uid     { role }
--   DELETE /admin/v1/projects/:id/members/:uid
-- Project knowledge:
--   GET    /admin/v1/projects/:id/knowledge
--   POST   /admin/v1/projects/:id/knowledge        (multipart or JSON with extracted_text)
--   GET    /admin/v1/projects/:id/knowledge/:kid   (single item with extracted_text)
--   PUT    /admin/v1/projects/:id/knowledge/:fname  (upsert by filename)
--   DELETE /admin/v1/projects/:id/knowledge/:kid
-- Project conversations:
--   GET    /admin/v1/projects/:id/conversations
--   GET    /admin/v1/projects/:id/feed

local json    = require("utils.json")
local storage = require("storage")
local proc    = require("utils.proc")

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
    ngx.header["Access-Control-Allow-Methods"]     = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
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

-- Returns the member row for (project_id, user) or sends 403/404 and returns nil.
-- Platform admins bypass membership checks.
local function require_project_access(project_id, min_role)
    local u = ngx.ctx.admin_user
    if u.role == "admin" then
        local proj, err = storage.get_project(project_id, nil, true)
        if not proj then send(404, { error = err or "not found" }); return nil end
        return proj, "admin"
    end
    local proj, err = storage.get_project(project_id, u.id, false)
    if not proj then
        if err == "not_found" then send(404, { error = "not found" })
        else send(403, { error = "forbidden" }) end
        return nil
    end
    local my_role = proj.my_role
    local rank = { owner = 3, editor = 2, viewer = 1 }
    if (rank[my_role] or 0) < (rank[min_role or "viewer"] or 0) then
        send(403, { error = "forbidden" }); return nil
    end
    return proj, my_role
end

function M.register(route)

    -- ── List projects ────────────────────────────────────────────────────────

    -- GET /admin/v1/projects
    route("GET", "^/admin/v1/projects$", function()
        local u       = ngx.ctx.admin_user
        local is_admin = u.role == "admin"
        -- tenant_admin / member / viewer scoped to their tenant
        local tenant_id = u.tenant_id
        if is_admin then
            -- platform admin: require ?tenant_id= query param
            local args = ngx.req.get_uri_args()
            tenant_id = args.tenant_id
            if not tenant_id then
                send(400, { error = "tenant_id query param required for admin" }); return
            end
        end
        local rows = storage.list_projects(tenant_id, u.id, is_admin)
        send(200, rows)
    end)

    -- ── Create project ───────────────────────────────────────────────────────

    -- POST /admin/v1/projects  { name, description?, instructions?, icon?, color?,
    --                            default_gateway_id?, default_model?, tenant_id? }
    route("POST", "^/admin/v1/projects$", function()
        local u    = ngx.ctx.admin_user
        local body = read_body()

        if not body.name or body.name == "" then
            send(400, { error = "name is required" }); return
        end

        -- Determine tenant: non-admin users always use their own tenant
        local tenant_id
        if u.role == "admin" then
            tenant_id = nullable(body.tenant_id) or u.tenant_id
            if not tenant_id then
                send(400, { error = "tenant_id is required" }); return
            end
        else
            tenant_id = u.tenant_id
        end

        -- Viewers may not create projects
        if u.role == "viewer" then
            send(403, { error = "forbidden" }); return
        end

        local id, err = storage.create_project({
            tenant_id          = tenant_id,
            name               = body.name,
            description        = nullable(body.description),
            instructions       = nullable(body.instructions),
            icon               = nullable(body.icon),
            color              = nullable(body.color),
            default_gateway_id = nullable(body.default_gateway_id),
            default_model      = nullable(body.default_model),
            created_by         = u.id,
        })
        if not id then send(500, { error = err or "create failed" }); return end

        local proj = storage.get_project(id, u.id, u.role == "admin")
        send(201, proj)
    end)

    -- ── Get project ──────────────────────────────────────────────────────────

    -- GET /admin/v1/projects/:id
    route("GET", "^/admin/v1/projects/([^/]+)$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        send(200, proj)
    end)

    -- ── Update project ───────────────────────────────────────────────────────

    -- PATCH /admin/v1/projects/:id  { name?, description?, instructions?, icon?, color?,
    --                                 default_gateway_id?, default_model? }
    route("PATCH", "^/admin/v1/projects/([^/]+)$", function(project_id)
        local proj, my_role = require_project_access(project_id, "editor")
        if not proj then return end
        _ = my_role  -- used only for access gate above

        local body = read_body()
        local data = {}
        for _, f in ipairs({"name","description","instructions","icon","color",
                             "default_gateway_id","default_model"}) do
            if body[f] ~= nil then data[f] = nullable(body[f]) end
        end
        if not next(data) then send(400, { error = "no fields to update" }); return end

        local _, err = storage.update_project(project_id, data)
        if err then send(500, { error = err }); return end

        local updated = storage.get_project(project_id, ngx.ctx.admin_user.id,
                                            ngx.ctx.admin_user.role == "admin")
        send(200, updated)
    end)

    -- ── Delete project ───────────────────────────────────────────────────────

    -- DELETE /admin/v1/projects/:id
    route("DELETE", "^/admin/v1/projects/([^/]+)$", function(project_id)
        local u = ngx.ctx.admin_user
        -- Only owner or platform admin may delete
        local proj, my_role = require_project_access(project_id, "owner")
        if not proj then return end
        if my_role ~= "admin" and my_role ~= "owner" then
            send(403, { error = "only project owners may delete a project" }); return
        end
        _ = u

        local _, err = storage.delete_project(project_id)
        if err then send(500, { error = err }); return end
        send(200, { ok = true })
    end)

    -- ── Members ──────────────────────────────────────────────────────────────

    -- POST /admin/v1/projects/:id/members  { user_id, role }
    route("POST", "^/admin/v1/projects/([^/]+)/members$", function(project_id)
        local _, my_role = require_project_access(project_id, "owner")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" then
            send(403, { error = "only project owners may add members" }); return
        end

        local body = read_body()
        if not body.user_id then send(400, { error = "user_id is required" }); return end
        local role = body.role or "viewer"
        if role ~= "owner" and role ~= "editor" and role ~= "viewer" then
            send(400, { error = "role must be owner|editor|viewer" }); return
        end

        local project, perr = storage.get_project(project_id, nil, true)
        local _, err = storage.add_project_member(project_id, body.user_id, role, ngx.ctx.admin_user.id)
        if err then send(500, { error = err }); return end
        if not perr and project then
            push.notify_user(body.user_id, "Added to project",
                "You were added to \"" .. (project.name or "a project") .. "\"",
                { type = "project_invite", project_id = project_id })
        end
        send(201, { ok = true })
    end)

    -- PATCH /admin/v1/projects/:id/members/:uid  { role }
    route("PATCH", "^/admin/v1/projects/([^/]+)/members/([^/]+)$", function(project_id, member_uid)
        local _, my_role = require_project_access(project_id, "owner")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" then
            send(403, { error = "only project owners may change roles" }); return
        end

        local body = read_body()
        local role = body.role
        if role ~= "owner" and role ~= "editor" and role ~= "viewer" then
            send(400, { error = "role must be owner|editor|viewer" }); return
        end

        -- Prevent removing last owner via role change
        if role ~= "owner" then
            local current = storage.get_project_member(project_id, member_uid)
            if current and current.role == "owner" then
                local n = storage.count_project_owners(project_id)
                if n <= 1 then
                    send(409, { error = "cannot demote the last owner" }); return
                end
            end
        end

        local _, err = storage.update_project_member_role(project_id, member_uid, role)
        if err then send(500, { error = err }); return end
        send(200, { ok = true })
    end)

    -- DELETE /admin/v1/projects/:id/members/:uid
    route("DELETE", "^/admin/v1/projects/([^/]+)/members/([^/]+)$", function(project_id, member_uid)
        local u = ngx.ctx.admin_user
        local _, my_role = require_project_access(project_id, "viewer")
        if not _ then return end

        -- Members may remove themselves; only owners/admin may remove others
        if member_uid ~= u.id and my_role ~= "admin" and my_role ~= "owner" then
            send(403, { error = "only project owners may remove members" }); return
        end

        -- Last-owner guard
        local current = storage.get_project_member(project_id, member_uid)
        if current and current.role == "owner" then
            local n = storage.count_project_owners(project_id)
            if n <= 1 then
                send(409, { error = "cannot remove the last owner" }); return
            end
        end

        local _, err = storage.remove_project_member(project_id, member_uid)
        if err then send(500, { error = err }); return end
        send(200, { ok = true })
    end)

    -- ── Knowledge ────────────────────────────────────────────────────────────

    -- GET /admin/v1/projects/:id/knowledge
    route("GET", "^/admin/v1/projects/([^/]+)/knowledge$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local rows = storage.list_project_knowledge(project_id)
        send(200, rows)
    end)

    -- POST /admin/v1/projects/:id/knowledge
    -- Body: { filename, content_type?, extracted_text, size_bytes? }
    -- (Frontend extracts text client-side or sends raw for small text files)
    route("POST", "^/admin/v1/projects/([^/]+)/knowledge$", function(project_id)
        local _, my_role = require_project_access(project_id, "editor")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" and my_role ~= "editor" then
            send(403, { error = "forbidden" }); return
        end

        local body = read_body()
        if not body.filename or body.filename == "" then
            send(400, { error = "filename is required" }); return
        end
        if body.extracted_text == nil then
            send(400, { error = "extracted_text is required" }); return
        end

        local id, err = storage.add_project_knowledge({
            project_id     = project_id,
            filename       = body.filename,
            content_type   = nullable(body.content_type) or "text/plain",
            size_bytes     = tonumber(body.size_bytes) or #body.extracted_text,
            extracted_text = body.extracted_text,
            created_by     = ngx.ctx.admin_user.id,
        })
        if not id then send(500, { error = err or "insert failed" }); return end

        -- Return metadata only (no text in response)
        local rows = storage.list_project_knowledge(project_id)
        local inserted
        for _, r in ipairs(rows) do
            if r.id == id then inserted = r; break end
        end
        send(201, inserted or { id = id })
    end)

    -- GET /admin/v1/projects/:id/knowledge/:kid
    -- Returns a single knowledge item including extracted_text (for download / reference)
    route("GET", "^/admin/v1/projects/([^/]+)/knowledge/([^/]+)$", function(project_id, kid)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local item = storage.get_project_knowledge_item(kid, project_id)
        if not item then send(404, { error = "not found" }); return end
        send(200, item)
    end)

    -- PUT /admin/v1/projects/:id/knowledge/:filename
    -- Body: { extracted_text, content_type?, size_bytes? }
    -- Upserts a knowledge entry by filename (insert or replace content).
    route("PUT", "^/admin/v1/projects/([^/]+)/knowledge/([^/]+)$", function(project_id, encoded_filename)
        local _, my_role = require_project_access(project_id, "editor")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" and my_role ~= "editor" then
            send(403, { error = "forbidden" }); return
        end

        local filename = ngx.unescape_uri(encoded_filename)
        local body = read_body()
        if body.extracted_text == nil then
            send(400, { error = "extracted_text is required" }); return
        end

        local text = body.extracted_text
        local ok, err = storage.upsert_project_knowledge({
            project_id     = project_id,
            filename       = filename,
            content_type   = nullable(body.content_type) or "text/plain",
            size_bytes     = tonumber(body.size_bytes) or #text,
            extracted_text = text,
            created_by     = ngx.ctx.admin_user.id,
        })
        if not ok then send(500, { error = err or "upsert failed" }); return end

        -- Return the updated metadata row
        local rows = storage.list_project_knowledge(project_id)
        local row
        for _, r in ipairs(rows) do
            if r.filename == filename then row = r; break end
        end
        send(200, row or { ok = true, filename = filename })
    end)

    -- DELETE /admin/v1/projects/:id/knowledge/:kid
    route("DELETE", "^/admin/v1/projects/([^/]+)/knowledge/([^/]+)$", function(project_id, kid)
        local _, my_role = require_project_access(project_id, "editor")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" and my_role ~= "editor" then
            send(403, { error = "forbidden" }); return
        end

        local _, err = storage.delete_project_knowledge(kid, project_id)
        if err then send(500, { error = err }); return end
        send(200, { ok = true })
    end)

    -- POST /admin/v1/projects/:id/knowledge/upload
    -- Body: { filename, mime_type, data: base64 }
    -- Decodes the binary, extracts text server-side, stores both text and original blob.
    -- Supported: application/pdf, .docx, .xlsx, .xls, .ods, .pptx
    route("POST", "^/admin/v1/projects/([^/]+)/knowledge/upload$", function(project_id)
        local _, my_role = require_project_access(project_id, "editor")
        if not _ then return end
        if my_role ~= "admin" and my_role ~= "owner" and my_role ~= "editor" then
            send(403, { error = "forbidden" }); return
        end

        local body = read_body()
        if not body.filename or body.filename == "" then
            send(400, { error = "filename is required" }); return
        end
        if not body.data or body.data == "" then
            send(400, { error = "data is required" }); return
        end

        local bin = ngx.decode_base64(body.data)
        if not bin then
            send(400, { error = "data is not valid base64" }); return
        end

        local MAX_BINARY = 20 * 1024 * 1024  -- 20 MB raw
        if #bin > MAX_BINARY then
            send(413, { error = "File exceeds 20 MB limit" }); return
        end

        local mime = body.mime_type or "application/octet-stream"
        local fname = body.filename
        local ext = fname:match("%.([^%.]+)$") or ""
        ext = ext:lower()

        -- Resolve mime from extension when browser sends a generic type
        if ext == "pdf"  then mime = "application/pdf" end
        if ext == "docx" then mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" end
        if ext == "xlsx" then mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" end
        if ext == "xls"  then mime = "application/vnd.ms-excel" end
        if ext == "ods"  then mime = "application/vnd.oasis.opendocument.spreadsheet" end
        if ext == "pptx" then mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" end

        local extracted_text = nil
        local rand_sfx = require("utils.crypto").random_hex(16)

        -- ── DOCX ─────────────────────────────────────────────────────────────
        if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" then
            local tmpfile = "/tmp/aig_proj_" .. rand_sfx .. ".docx"
            local f = io.open(tmpfile, "wb"); if f then f:write(bin); f:close() end
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
except Exception:
    sys.exit(1)
]])
                sf:close()
            end
            local exit_code
            extracted_text, exit_code = proc.run({"python3", script, tmpfile})
            os.remove(tmpfile); os.remove(script)
            extracted_text = extracted_text:gsub("^%s+", ""):gsub("%s+$", "")
            if exit_code ~= 0 or extracted_text == "" then
                send(422, { error = "Could not extract text from .docx file" }); return
            end

        -- ── XLSX / XLS ────────────────────────────────────────────────────────
        elseif mime == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            or mime == "application/vnd.ms-excel"
            or mime == "application/vnd.ms-excel.sheet.macroenabled.12" then
            local tmpfile = "/tmp/aig_proj_" .. rand_sfx .. ".xlsx"
            local f = io.open(tmpfile, "wb"); if f then f:write(bin); f:close() end
            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, csv, re
import xml.etree.ElementTree as ET
NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
def col_index(ref):
    col = re.sub(r'\d+', '', ref)
    result = 0
    for c in col:
        result = result * 26 + (ord(c.upper()) - ord('A') + 1)
    return result - 1
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        names = z.namelist()
        shared = []
        if 'xl/sharedStrings.xml' in names:
            root = ET.fromstring(z.read('xl/sharedStrings.xml'))
            for si in root.findall('{' + NS + '}si'):
                parts = [t.text or '' for t in si.iter('{' + NS + '}t')]
                shared.append(''.join(parts))
        sheets = sorted([n for n in names if re.match(r'xl/worksheets/sheet\d+\.xml', n)])
        w = csv.writer(sys.stdout, lineterminator='\n')
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
            local exit_code
            extracted_text, exit_code = proc.run({"python3", script, tmpfile})
            os.remove(tmpfile); os.remove(script)
            extracted_text = extracted_text:gsub("^%s+", ""):gsub("%s+$", "")
            if exit_code ~= 0 or extracted_text == "" then
                send(422, { error = "Could not convert spreadsheet to CSV" }); return
            end

        -- ── ODS ───────────────────────────────────────────────────────────────
        elseif mime == "application/vnd.oasis.opendocument.spreadsheet" then
            local tmpfile = "/tmp/aig_proj_" .. rand_sfx .. ".ods"
            local f = io.open(tmpfile, "wb"); if f then f:write(bin); f:close() end
            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, csv
import xml.etree.ElementTree as ET
NS = {'t': 'urn:oasis:names:tc:opendocument:xmlns:table:1.0',
      'tx': 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'}
try:
    z = zipfile.ZipFile(sys.argv[1])
    root = ET.fromstring(z.read('content.xml'))
    w = csv.writer(sys.stdout, lineterminator='\n')
    for sheet in root.findall('.//t:table', NS):
        for row in sheet.findall('t:table-row', NS):
            cells = []
            for cell in row.findall('t:table-cell', NS):
                repeat_n = int(cell.get('{urn:oasis:names:tc:opendocument:xmlns:table:1.0}number-columns-repeated') or 1)
                parts = [p.text or '' for p in cell.findall('.//tx:p', NS)]
                val = ' '.join(parts)
                cells.extend([val] * repeat_n)
            while cells and cells[-1] == '':
                cells.pop()
            if cells:
                w.writerow(cells)
except Exception:
    sys.exit(1)
]])
                sf:close()
            end
            local exit_code
            extracted_text, exit_code = proc.run({"python3", script, tmpfile})
            os.remove(tmpfile); os.remove(script)
            extracted_text = extracted_text:gsub("^%s+", ""):gsub("%s+$", "")
            if exit_code ~= 0 or extracted_text == "" then
                send(422, { error = "Could not convert .ods to CSV" }); return
            end

        -- ── PPTX ──────────────────────────────────────────────────────────────
        elseif mime == "application/vnd.openxmlformats-officedocument.presentationml.presentation" then
            local tmpfile = "/tmp/aig_proj_" .. rand_sfx .. ".pptx"
            local f = io.open(tmpfile, "wb"); if f then f:write(bin); f:close() end
            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, zipfile, re
import xml.etree.ElementTree as ET
try:
    z = zipfile.ZipFile(sys.argv[1])
    slides = sorted([n for n in z.namelist() if re.match(r'ppt/slides/slide\d+\.xml', n)],
                    key=lambda x: int(re.search(r'\d+', x).group()))
    NS = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    texts = []
    for name in slides:
        root = ET.fromstring(z.read(name).decode('utf-8', 'replace'))
        slide_texts = [t.text for t in root.iter('{' + NS + '}t') if t.text and t.text.strip()]
        if slide_texts:
            texts.append('\n'.join(slide_texts))
    print('\n\n---\n\n'.join(texts))
except Exception:
    sys.exit(1)
]])
                sf:close()
            end
            local exit_code
            extracted_text, exit_code = proc.run({"python3", script, tmpfile})
            os.remove(tmpfile); os.remove(script)
            extracted_text = extracted_text:gsub("^%s+", ""):gsub("%s+$", "")
            if exit_code ~= 0 or extracted_text == "" then
                send(422, { error = "Could not extract text from .pptx file" }); return
            end

        -- ── PDF ───────────────────────────────────────────────────────────────
        elseif mime == "application/pdf" then
            local tmpfile = "/tmp/aig_proj_" .. rand_sfx .. ".pdf"
            local f = io.open(tmpfile, "wb"); if f then f:write(bin); f:close() end
            local script = tmpfile .. ".py"
            local sf = io.open(script, "w")
            if sf then
                sf:write([[
import sys, base64, json, io, fitz
from urllib.request import urlopen, Request
from PIL import Image, ImageEnhance, ImageFilter

MINERU_URL     = "http://172.28.0.1:8084/v1/chat/completions"
MAX_PAGES      = 20
TEXT_THRESHOLD = 50
STRIPS         = 2
FOOTER_RATIO   = 0.91

def extract_page_text(page):
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
        text = extract_page_text(page)
        if len(text) >= TEXT_THRESHOLD:
            pages_md.append(text)
            continue
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
            local exit_code
            extracted_text, exit_code = proc.run({"python3", script, tmpfile}, nil, {timeout_ms = 300000})
            os.remove(tmpfile); os.remove(script)
            extracted_text = extracted_text:gsub("^%s+", ""):gsub("%s+$", "")
            if exit_code ~= 0 or extracted_text == "" then
                send(422, { error = "Could not extract text from PDF" }); return
            end

        else
            send(422, { error = "Unsupported file type: " .. mime .. ". Use the plain-text upload for .txt/.md/.csv files." }); return
        end

        -- Persist knowledge row + blob
        local token_count = math.floor(#extracted_text / 4)
        local id, err = storage.add_project_knowledge({
            project_id     = project_id,
            filename       = fname,
            content_type   = mime,
            size_bytes     = #bin,
            extracted_text = extracted_text,
            token_count    = token_count,
            source         = "upload",
            created_by     = ngx.ctx.admin_user.id,
        })
        if not id then send(500, { error = err or "insert failed" }); return end

        local blob_err = storage.store_project_knowledge_blob(id, bin)
        if blob_err then
            -- Non-fatal: metadata was saved; blob storage failure is logged but not surfaced
            ngx.log(ngx.ERR, "blob store failed for knowledge " .. id .. ": " .. tostring(blob_err))
        end

        -- Return the newly created metadata row
        local rows = storage.list_project_knowledge(project_id)
        local inserted
        for _, r in ipairs(rows) do
            if r.id == id then inserted = r; break end
        end
        send(201, inserted or { id = id })
    end)

    -- GET /admin/v1/projects/:id/knowledge/:kid/download
    -- Returns the original binary for files uploaded via /knowledge/upload.
    -- Must come before the generic /knowledge/:kid route.
    route("GET", "^/admin/v1/projects/([^/]+)/knowledge/([^/]+)/download$", function(project_id, kid)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local item = storage.get_project_knowledge_item(kid, project_id)
        if not item then send(404, { error = "not found" }); return end
        if item.source ~= "upload" then
            send(404, { error = "no original file stored for this entry" }); return
        end
        local blob = storage.get_project_knowledge_blob(kid)
        if not blob then send(404, { error = "blob not found" }); return end
        ngx.header["Content-Type"]        = item.content_type or "application/octet-stream"
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. item.filename .. '"'
        ngx.header["Content-Length"]      = #blob
        ngx.status = 200
        ngx.print(blob)
        ngx.exit(200)
    end)

    -- ── Project conversations ─────────────────────────────────────────────────

    -- GET /admin/v1/projects/:id/conversations?limit=50
    route("GET", "^/admin/v1/projects/([^/]+)/conversations$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local args  = ngx.req.get_uri_args()
        local rows  = storage.list_project_conversations(project_id, tonumber(args.limit))
        send(200, rows)
    end)

    -- GET /admin/v1/projects/:id/feed?limit=20&offset=0
    -- Returns conversations shared to the project feed (shared_in_project = 1),
    -- ordered by shared_at DESC. Visible to all project members.
    route("GET", "^/admin/v1/projects/([^/]+)/feed$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local args   = ngx.req.get_uri_args()
        local limit  = tonumber(args.limit) or 20
        local offset = tonumber(args.offset) or 0
        local rows   = storage.list_project_feed(project_id, limit, offset)
        send(200, rows)
    end)

    -- ── Knowledge text (for context injection) ────────────────────────────────

    -- GET /admin/v1/projects/:id/knowledge-text
    -- Returns full extracted_text for all knowledge files (used by Chat.tsx to build system prompt)
    route("GET", "^/admin/v1/projects/([^/]+)/knowledge%-text$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local rows = storage.get_project_knowledge_text(project_id)
        send(200, rows)
    end)

end

return M
