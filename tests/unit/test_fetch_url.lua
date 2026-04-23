-- tests/unit/test_fetch_url.lua
-- Unit tests for utils/fetch_url.lua: SSRF guard, HTML extraction, parallel.

_G.ngx = {
    log    = function() end,
    ERR = 0, WARN = 1, INFO = 2,
    thread = {
        spawn = function(fn, ...)
            local args = {...}
            return { fn = fn, args = args }
        end,
        wait  = function(t) return pcall(t.fn, unpack(t.args)) end,
        kill  = function(t) t.killed = true end,
    },
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear()
    for _, n in ipairs({"utils.fetch_url", "resty.http"}) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

local function mock_http(resp_or_err)
    package.preload["resty.http"] = function()
        return {
            new = function()
                return {
                    set_timeout = function() end,
                    request_uri = function(self, url, opts)
                        if type(resp_or_err) == "string" then
                            return nil, resp_or_err
                        end
                        return resp_or_err, nil
                    end,
                }
            end,
        }
    end
end

local function html_resp(body)
    return { status = 200, headers = { ["Content-Type"] = "text/html; charset=utf-8" }, body = body }
end

-- ── SSRF guard ────────────────────────────────────────────────────────────────

describe("fetch_url: SSRF guard — blocked addresses", function()
    local blocked = {
        "http://127.0.0.1/",
        "http://127.1.2.3/path",
        "http://10.0.0.1/api",
        "http://10.255.255.255/",
        "http://192.168.1.1/router",
        "http://192.168.100.100/",
        "http://172.16.0.1/",
        "http://172.20.0.1/",
        "http://172.31.255.255/",
        "http://169.254.169.254/latest/meta-data/",  -- AWS metadata
        "http://169.254.0.1/",
        "http://0.1.2.3/",
        "http://localhost/",
        "http://LOCALHOST/",
    }
    for _, url in ipairs(blocked) do
        local u = url
        it("blocks " .. u, function()
            clear()
            -- mock should never be called for blocked URLs
            local called = false
            mock_http(setmetatable({}, {
                __index = function() called = true; return nil end
            }))
            local fu = require("utils.fetch_url")
            local result = fu.fetch(u)
            assert.is_nil(result)
            assert.is_false(called, "HTTP should not be called for blocked URL")
        end)
    end
end)

describe("fetch_url: SSRF guard — allowed addresses", function()
    it("allows public IPs through", function()
        clear()
        mock_http(html_resp("<body>ok</body>"))
        local fu = require("utils.fetch_url")
        -- Should reach the HTTP mock (not blocked) and return content
        local result = fu.fetch("http://8.8.8.8/")
        assert.not_nil(result)
    end)

    it("allows public hostnames through", function()
        clear()
        mock_http(html_resp("<body>hello</body>"))
        local fu = require("utils.fetch_url")
        local result = fu.fetch("http://example.com/page")
        assert.not_nil(result)
    end)

    it("rejects URLs with no host", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        local result = fu.fetch("not-a-url")
        assert.is_nil(result)
    end)
end)

-- ── HTML extraction ───────────────────────────────────────────────────────────

describe("fetch_url: HTML-to-text extraction", function()
    before_each(clear)

    it("strips tags", function()
        mock_http(html_resp("<body><p>Hello World</p></body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert.not_nil(text)
        assert(not text:find("<"), "should not contain < after stripping")
        assert(text:find("Hello World"), "should contain text content")
    end)

    it("decodes &amp;", function()
        mock_http(html_resp("<body>fish &amp; chips</body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert(text:find("fish & chips"), "should decode &amp;")
    end)

    it("decodes &lt; &gt;", function()
        mock_http(html_resp("<body>1 &lt; 2 &gt; 0</body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert(text:find("1 < 2 > 0"), "should decode &lt; and &gt;")
    end)

    it("decodes &quot; and &#039;", function()
        mock_http(html_resp("<body>&quot;hello&quot; it&#039;s</body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert(text:find('"hello"'), "should decode &quot;")
        assert(text:find("it's"), "should decode &#039;")
    end)

    it("collapses whitespace", function()
        mock_http(html_resp("<body>a    b\n\tc</body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert(not text:find("  "), "should collapse multiple spaces")
    end)

    it("prefers <body> content — skips <head> CSS/JS noise", function()
        mock_http(html_resp(
            "<html><head><style>.cls{color:red;font-size:14px}</style></head>" ..
            "<body>Visible content only</body></html>"
        ))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert(text:find("Visible content"), "should contain body text")
        assert(not text:find("color:red"), "should not contain CSS from head")
    end)

    it("truncates long pages at 6000 chars with ellipsis", function()
        mock_http(html_resp("<body>" .. string.rep("X", 8000) .. "</body>"))
        local text = require("utils.fetch_url").fetch("http://example.com/")
        assert.not_nil(text)
        -- text is truncated body: "X"*6000 + "…"
        assert(#text <= 6020, "text length " .. #text .. " should be <=6020")
        -- The UTF-8 ellipsis is 3 bytes; check last character
        local last = text:sub(-3)
        assert(last == "…" or text:sub(-1) == "…",
               "truncated text should end with ellipsis")
    end)

    it("returns nil for non-HTML content type", function()
        mock_http({ status = 200,
                    headers = { ["Content-Type"] = "application/pdf" },
                    body = "%PDF-1.4 content" })
        local result = require("utils.fetch_url").fetch("http://example.com/doc.pdf")
        assert.is_nil(result)
    end)

    it("returns nil for HTTP 4xx", function()
        mock_http({ status = 404, headers = { ["Content-Type"] = "text/html" }, body = "Not Found" })
        local result = require("utils.fetch_url").fetch("http://example.com/missing")
        assert.is_nil(result)
    end)

    it("returns nil for HTTP 5xx", function()
        mock_http({ status = 503, headers = { ["Content-Type"] = "text/html" }, body = "Unavailable" })
        local result = require("utils.fetch_url").fetch("http://example.com/")
        assert.is_nil(result)
    end)

    it("returns nil on network error", function()
        mock_http("connection refused")
        local result = require("utils.fetch_url").fetch("http://example.com/")
        assert.is_nil(result)
    end)

    it("accepts text/plain content type", function()
        mock_http({ status = 200,
                    headers = { ["Content-Type"] = "text/plain" },
                    body = "Plain text content" })
        local text = require("utils.fetch_url").fetch("http://example.com/readme.txt")
        assert.not_nil(text)
        assert(text:find("Plain text"), "should return plain text content")
    end)
end)

-- ── M.parallel ────────────────────────────────────────────────────────────────

describe("fetch_url.parallel", function()
    before_each(clear)

    it("returns empty table for 0 URLs", function()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        local out = fu.parallel({}, 0)
        assert.equal(0, #out)
    end)

    it("n=1 returns single {url, text} without spawning threads", function()
        local spawned = 0
        _G.ngx.thread.spawn = function(fn, ...) spawned = spawned + 1; return {fn=fn,args={...}} end
        mock_http(html_resp("<body>content</body>"))
        local fu = require("utils.fetch_url")
        local out = fu.parallel({"http://example.com/"}, 1)
        assert.equal(0, spawned, "n=1 should not use thread.spawn")
        assert.equal(1, #out)
        assert.equal("http://example.com/", out[1].url)
        assert.not_nil(out[1].text)
    end)

    it("n=2 spawns 2 threads and returns 2 entries", function()
        local spawned = 0
        _G.ngx.thread.spawn = function(fn, ...)
            spawned = spawned + 1
            return { fn = fn, args = {...} }
        end
        _G.ngx.thread.wait = function(t) return pcall(t.fn, unpack(t.args)) end
        mock_http(html_resp("<body>page</body>"))
        local fu = require("utils.fetch_url")
        local out = fu.parallel({"http://a.com/", "http://b.com/"}, 2)
        assert.equal(2, spawned)
        assert.equal(2, #out)
        assert.equal("http://a.com/", out[1].url)
        assert.equal("http://b.com/", out[2].url)
    end)

    it("fills nil text when fetch returns nil (SSRF blocked)", function()
        mock_http(html_resp("<body>ok</body>"))
        local fu = require("utils.fetch_url")
        -- 127.0.0.1 is blocked → nil text; example.com is allowed → text
        local out = fu.parallel({"http://127.0.0.1/", "http://example.com/"}, 2)
        assert.equal(2, #out)
        assert.is_nil(out[1].text, "blocked URL should yield nil text")
        assert.not_nil(out[2].text, "allowed URL should yield text")
    end)

    it("kills remaining threads and returns full-length array on thread error", function()
        local killed = {}
        _G.ngx.thread.spawn = function(fn, ...) return { fn = fn, args = {...} } end
        local wait_calls = 0
        _G.ngx.thread.wait = function(t)
            wait_calls = wait_calls + 1
            if wait_calls == 1 then return false, "simulated error" end
            return pcall(t.fn, unpack(t.args))
        end
        _G.ngx.thread.kill = function(t) killed[#killed + 1] = t end

        mock_http(html_resp("<body>ok</body>"))
        local fu = require("utils.fetch_url")
        fu.parallel({"http://a.com/", "http://b.com/"}, 2)
        assert(#killed >= 1, "should kill thread[2] after thread[1] fails")
    end)
end)

-- ── SSRF guard — new bypass vectors (Finding 6) ───────────────────────────────

describe("fetch_url: SSRF guard — IPv4-mapped IPv6 bypass (Finding 6)", function()
    local blocked_ipv6 = {
        "http://[::ffff:169.254.169.254]/",   -- AWS metadata via IPv4-mapped IPv6
        "http://[::ffff:127.0.0.1]/",          -- loopback
        "http://[::ffff:10.0.0.1]/",           -- RFC1918
        "http://[::ffff:192.168.1.1]/",        -- RFC1918
        "http://[::ffff:172.16.0.1]/",         -- RFC1918
        "http://::ffff:169.254.169.254/",      -- without brackets
        "http://::ffff:10.0.0.1/",
    }
    for _, url in ipairs(blocked_ipv6) do
        local u = url
        it("blocks IPv4-mapped IPv6: " .. u, function()
            clear()
            local called = false
            mock_http(setmetatable({}, { __index = function() called = true; return nil end }))
            local fu = require("utils.fetch_url")
            local result = fu.fetch(u)
            assert.is_nil(result)
            assert.is_false(called, "HTTP must not be called for " .. u)
        end)
    end
end)

describe("fetch_url: SSRF guard — IPv6 ULA and link-local (Finding 6)", function()
    local blocked_ipv6_ula = {
        "http://[fd00::1]/",        -- IPv6 ULA
        "http://[fd12:3456::1]/",   -- IPv6 ULA
        "http://[fc00::1]/",        -- IPv6 ULA fc00::/8
        "http://[fe80::1]/",        -- IPv6 link-local
        "http://[fe89::1]/",        -- IPv6 link-local fe80::/10
        "http://[feab::1]/",        -- IPv6 link-local
    }
    for _, url in ipairs(blocked_ipv6_ula) do
        local u = url
        it("blocks IPv6 ULA/link-local: " .. u, function()
            clear()
            local called = false
            mock_http(setmetatable({}, { __index = function() called = true; return nil end }))
            local fu = require("utils.fetch_url")
            local result = fu.fetch(u)
            assert.is_nil(result)
            assert.is_false(called, "HTTP must not be called for " .. u)
        end)
    end
end)

describe("fetch_url: SSRF guard — decimal-encoded IP (Finding 6)", function()
    it("blocks 2852039166 (decimal for 169.254.169.254)", function()
        clear()
        local called = false
        mock_http(setmetatable({}, { __index = function() called = true; return nil end }))
        local fu = require("utils.fetch_url")
        -- 169*256^3 + 254*256^2 + 169*256 + 254 = 2852039166
        local result = fu.fetch("http://2852039166/latest/meta-data/")
        assert.is_nil(result)
        assert.is_false(called, "decimal 169.254.169.254 must be blocked")
    end)

    it("blocks 2130706433 (decimal for 127.0.0.1)", function()
        clear()
        local called = false
        mock_http(setmetatable({}, { __index = function() called = true; return nil end }))
        local fu = require("utils.fetch_url")
        local result = fu.fetch("http://2130706433/")
        assert.is_nil(result)
        assert.is_false(called, "decimal 127.0.0.1 must be blocked")
    end)

    it("allows a decimal-encoded public IP (8.8.8.8 = 134744072)", function()
        clear()
        mock_http(html_resp("<body>ok</body>"))
        local fu = require("utils.fetch_url")
        -- 8*256^3 + 8*256^2 + 8*256 + 8 = 134744072
        local result = fu.fetch("http://134744072/")
        assert.not_nil(result, "public IP in decimal form should be allowed")
    end)
end)

describe("fetch_url: M.is_safe_url exported function (Finding 6)", function()
    it("M.is_safe_url is exported on the module table", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        assert.not_nil(fu.is_safe_url, "is_safe_url must be exported")
        assert.equal("function", type(fu.is_safe_url))
    end)

    it("is_safe_url returns false for a private IP URL", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        assert.is_false(fu.is_safe_url("http://192.168.1.1/"))
    end)

    it("is_safe_url returns false for IPv4-mapped IPv6", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        assert.is_false(fu.is_safe_url("http://[::ffff:10.0.0.1]/"))
    end)

    it("is_safe_url returns true for a public IP URL", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        assert.is_true(fu.is_safe_url("http://1.1.1.1/"))
    end)

    it("is_safe_url returns true for a public hostname URL", function()
        clear()
        mock_http(html_resp("<body>x</body>"))
        local fu = require("utils.fetch_url")
        assert.is_true(fu.is_safe_url("https://api.example.com/v1/chat"))
    end)
end)
