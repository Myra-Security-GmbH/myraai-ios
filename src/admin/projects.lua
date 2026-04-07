-- admin/projects.lua — Projects API routes
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

local json    = require("utils.json")
local storage = require("storage")

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

        -- Only tenant_admin+ may create projects (members/viewers cannot)
        if u.role ~= "admin" and u.role ~= "tenant_admin" then
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

        local _, err = storage.add_project_member(project_id, body.user_id, role, ngx.ctx.admin_user.id)
        if err then send(500, { error = err }); return end
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

    -- ── Project conversations ─────────────────────────────────────────────────

    -- GET /admin/v1/projects/:id/conversations?limit=50
    route("GET", "^/admin/v1/projects/([^/]+)/conversations$", function(project_id)
        local proj = require_project_access(project_id, "viewer")
        if not proj then return end
        local args  = ngx.req.get_uri_args()
        local rows  = storage.list_project_conversations(project_id, tonumber(args.limit))
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
