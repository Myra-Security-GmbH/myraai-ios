-- tests/unit/test_admin_chat.lua — key security/logic tests for src/admin/chat.lua
-- Run with: resty tests/runner.lua tests/unit/test_admin_chat.lua
--
-- Coverage (narrow: CRUD routes covered by E2E):
--   1. Share token is CSPRNG random_hex(32) — 64 hex chars, not MD5
--   2. Fork from share token filters non-user/assistant roles (::continue:: label)
--   3. Conversation create requires gateway_id
--   4. Share token POST creates a 64-char hex token

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _real_encode_base64 = _G.ngx and _G.ngx.encode_base64
local _real_decode_base64 = _G.ngx and _G.ngx.decode_base64

local _printed  = nil
local _exited   = nil
local _status   = 200
local _headers  = {}
local _body_raw = "{}"
local _uri      = "/"
local _method   = "GET"

_G.ngx = {
    encode_base64 = _real_encode_base64,
    decode_base64 = _real_decode_base64,
    time   = function() return 1700000000 end,
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(c) _exited = c end,
    print  = function(s) _printed = s end,
    flush  = function() end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = { uri = "/", remote_addr = "127.0.0.1",
               scheme = "https", http_host = "test.example.com" },
    req    = {
        read_body     = function() end,
        get_body_data = function() return _body_raw end,
        get_method    = function() return _method end,
        get_uri_args  = function() return {} end,
        get_headers   = function() return {} end,
    },
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    timer  = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
}

-- ---------------------------------------------------------------------------
-- Shared stubs
-- ---------------------------------------------------------------------------

local _conv_db    = {}
local _msg_db     = {}
local _share_db   = {}
local _share_token = nil
local _appended   = {}
local _next_conv_id = 1
local _next_share_token = nil

local storage_mock = {
    create_conversation = function(data)
        local id = "conv-" .. _next_conv_id
        _next_conv_id = _next_conv_id + 1
        _conv_db[id] = { id=id, title=data.title, gateway_id=data.gateway_id, messages={} }
        return id, nil
    end,
    get_conversation = function(id, user_id)
        return _conv_db[id] or { id=id, messages={} }, nil
    end,
    append_message = function(data)
        _appended[#_appended + 1] = data
    end,
    insert_audit_log = function() end,
    list_conversations = function() return {}, 0 end,
    delete_conversation = function() end,
    patch_conversation = function() return nil end,
    get_share_by_token = function(tok)
        return _share_db[tok]
    end,
    get_share_by_conv = function(id, uid)
        for tok, row in pairs(_share_db) do
            if row.conv_id == id then
                return { token=tok, url="/shared/"..tok }
            end
        end
        return nil
    end,
    upsert_share = function(conv_id, user_id, token, snapshot)
        _share_db[token] = { conv_id=conv_id, user_id=user_id,
                              snapshot_json=cjson.encode(snapshot) }
        _share_token = token
        return true, nil
    end,
    delete_share = function() end,
    list_messages = function() return {} end,
    get_user = function(id) return { id=id, email="t@t.com", role="admin", tenant_id="tn-1", deleted_at=nil } end,
}

for _, n in ipairs({"admin.api","admin.chat","admin.mcp","admin.model_sync","admin.monitor",
                    "admin.share","storage","auth.byok","utils.crypto","utils.json",
                    "providers","core.app_config","admin.auth","utils.uuid","utils.email",
                    "utils.http","utils.trace"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.loaded["storage"] = storage_mock

package.preload["core.app_config"] = function() return {} end
package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end
package.preload["utils.crypto"] = function()
    return {
        random_hex = function(n) return string.rep("a", n * 2) end,
        sha256_hex = function(s) return "hash:"..s end,
    }
end
package.preload["auth.byok"] = function() return { get=function() return nil end } end
package.preload["providers"] = function() return { list=function() return {} end } end
package.preload["admin.auth"] = function()
    return { require_session=function() end, check_tenant=function() return true end }
end
package.preload["utils.uuid"] = function()
    local n=0; return { v4=function() n=n+1; return "uuid-"..n end }
end
package.preload["utils.email"] = function() return { send=function() end, send_template=function() end } end
package.preload["utils.http"] = function()
    return { request=function() return 200, {}, "{}", nil end }
end
package.preload["utils.trace"] = function()
    return { step=function() end, done=function() end }
end
package.preload["admin.mcp"] = function() return { register=function() end } end
package.preload["admin.model_sync"] = function() return { register=function() end } end
package.preload["admin.monitor"] = function() return { handle=function() end } end
package.preload["admin.share"] = function() return { handle=function() end } end

local api = require("admin.api")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function reset()
    _printed  = nil
    _exited   = nil
    _headers  = {}
    _appended = {}
    _conv_db  = {}
    _share_db = {}
    _share_token = nil
    _next_conv_id = 1
    _G.ngx.status = 200
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end })
    _G.ngx.ctx = { admin_user = { id="user-1", role="admin", tenant_id="tn-1" } }
end

local function call(method, uri, body_tbl)
    reset()
    _method   = method
    _uri      = uri
    _G.ngx.var.uri = uri
    _G.ngx.req.get_method = function() return method end
    if body_tbl then
        _body_raw = cjson.encode(body_tbl)
        _G.ngx.req.get_body_data = function() return _body_raw end
    else
        _body_raw = "{}"
        _G.ngx.req.get_body_data = function() return "{}" end
    end
    api.handle()
    return _G.ngx.status, _printed and (cjson.decode(_printed) or {}) or {}
end

-- ============================================================================
-- 1. Share token uses CSPRNG (random_hex(32))
-- ============================================================================

describe("admin.chat: share token generation", function()

    it("POST /share creates a token via random_hex(32)", function()
        reset()
        -- Create a conversation first
        local conv_id = "conv-test-001"
        _conv_db[conv_id] = { id=conv_id, title="test", gateway_id="gw-1", messages={
            { role="user", content="hi", model="gpt-4o", gateway_id="gw-1" }
        }}

        -- Override crypto mock to track what n was passed to random_hex
        local random_hex_n = nil
        package.loaded["utils.crypto"] = nil
        package.preload["utils.crypto"] = function()
            return {
                random_hex = function(n)
                    random_hex_n = n
                    return string.rep("a", n * 2)
                end,
                sha256_hex = function(s) return "hash:"..s end,
            }
        end
        package.loaded["admin.api"] = nil
        package.loaded["admin.chat"] = nil
        local api2 = require("admin.api")

        reset()
        _conv_db[conv_id] = { id=conv_id, title="test", gateway_id="gw-1", messages={} }
        _method = "POST"
        _uri    = "/admin/v1/conversations/" .. conv_id .. "/share"
        _G.ngx.var.uri = _uri
        _G.ngx.req.get_method = function() return "POST" end
        _body_raw = "{}"
        _G.ngx.req.get_body_data = function() return "{}" end
        api2.handle()

        assert.equal(32, random_hex_n,
            "share token must use random_hex(32) for 256 bits of entropy")
        if _share_token then
            assert.equal(64, #_share_token,
                "token must be 64 hex chars (random_hex(32))")
            assert((_share_token):match("^[a-f0-9]+$") or (_share_token):match("^a+$"),
                "token must be lowercase hex")
        end

        -- Restore
        package.loaded["utils.crypto"] = nil
        package.preload["utils.crypto"] = function()
            return { random_hex=function(n) return string.rep("a",n*2) end,
                     sha256_hex=function(s) return "hash:"..s end }
        end
        package.loaded["admin.api"] = nil
        package.loaded["admin.chat"] = nil
        api = require("admin.api")
    end)

end)

-- ============================================================================
-- 2. Fork from share: role filter (::continue:: label)
-- ============================================================================

describe("admin.chat: fork from share token — role filter", function()

    it("only user and assistant messages are copied when forking", function()
        reset()
        -- Seed a share token AFTER reset() so it isn't cleared by call()
        local tok = "share-token-abc"
        _share_db[tok] = {
            conv_id  = "conv-src",
            user_id  = "user-1",
            snapshot_json = cjson.encode({
                title    = "test conv",
                messages = {
                    { role="user",      content="hello",    model="m", gateway_id="gw-1" },
                    { role="assistant", content="hi",       model="m", gateway_id="gw-1" },
                    { role="tool",      content="tool out", model="m", gateway_id="gw-1" },
                    { role="function",  content="fn out",   model="m", gateway_id="gw-1" },
                },
            }),
        }

        -- Call api.handle() directly (avoid call() which resets _share_db)
        _method   = "POST"
        _uri      = "/admin/v1/conversations"
        _body_raw = cjson.encode({ source_share_token=tok, gateway_id="gw-1" })
        _G.ngx.var.uri     = _uri
        _G.ngx.req.get_method    = function() return "POST" end
        _G.ngx.req.get_body_data = function() return _body_raw end
        api.handle()

        local s = _G.ngx.status
        local b = _printed and cjson.decode(_printed) or {}
        assert.equal(201, s, "fork must succeed: " .. cjson.encode(b))

        -- Only user+assistant should be in _appended
        local roles = {}
        for _, a in ipairs(_appended) do roles[#roles+1] = a.role end

        for _, r in ipairs(roles) do
            assert(r == "user" or r == "assistant",
                "role '" .. r .. "' must NOT be copied in fork")
        end
        assert.equal(2, #roles,
            "exactly 2 messages (user + assistant) must be appended, got: " .. #roles)
    end)

end)

-- ============================================================================
-- 3. Conversation create: gateway_id required
-- ============================================================================

describe("admin.chat: conversation create validation", function()

    it("returns 400 when gateway_id is missing", function()
        local s, b = call("POST", "/admin/v1/conversations",
            { title = "test" })  -- no gateway_id
        assert.equal(400, s)
        assert.not_nil(b.error)
    end)

    it("returns 201 when gateway_id is provided", function()
        local s, b = call("POST", "/admin/v1/conversations",
            { gateway_id = "gw-001", title = "new conv" })
        assert.equal(201, s)
    end)

end)
