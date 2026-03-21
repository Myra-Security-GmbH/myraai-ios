-- utils/fetch_url.lua — HTTP page fetcher with SSRF guard and HTML-to-text
--
-- Fetches a public web page and returns plain text suitable for LLM context.
-- Parallel fetches use ngx.thread.spawn (non-blocking cosocket).
--
-- Security: rejects loopback, RFC1918, link-local, and AWS metadata addresses.

local http_lib = require("resty.http")

local M = {}

local MAX_CHARS = 6000
local TIMEOUT_MS = 5000

-- ── SSRF guard ────────────────────────────────────────────────────────────────

local BLOCKED_PATTERNS = {
    "^127%.",         -- loopback
    "^10%.",          -- RFC1918
    "^192%.168%.",    -- RFC1918
    "^172%.1[6-9]%.", -- RFC1918 172.16-19.x
    "^172%.2%d%.",    -- RFC1918 172.20-29.x
    "^172%.3[01]%.",  -- RFC1918 172.30-31.x
    "^169%.254%.",    -- link-local / AWS metadata
    "^0%.",           -- "this" network
    "^::1$",          -- IPv6 loopback
    "^localhost$",
}

local function is_safe_host(host)
    host = host:lower()
    for _, pat in ipairs(BLOCKED_PATTERNS) do
        if host:match(pat) then return false end
    end
    return true
end

local function is_safe_url(url)
    local host = url:match("https?://([^/:?#]+)")
    return host and is_safe_host(host)
end

-- ── HTML → plain text ─────────────────────────────────────────────────────────

local function html_to_text(s)
    if not s or s == "" then return "" end

    -- Prefer body content to skip <head> CSS/JS noise
    local body_pos = s:find("<body[^>]*>")
    if body_pos then s = s:sub(body_pos) end

    -- Strip all tags
    s = s:gsub("<[^>]+>", " ")

    -- Decode common HTML entities
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#039;", "'")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("&#(%d+);", function(n)
        local c = tonumber(n)
        return c and c < 128 and string.char(c) or " "
    end)

    -- Collapse whitespace
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or ""
    return s
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Fetch one URL and return plain text, or nil on any error.
function M.fetch(url)
    if not is_safe_url(url) then
        ngx.log(ngx.WARN, "fetch_url: blocked SSRF url=", url)
        return nil
    end

    local httpc = http_lib.new()
    httpc:set_timeout(TIMEOUT_MS)

    local res, err = httpc:request_uri(url, {
        method     = "GET",
        headers    = {
            ["Accept"]          = "text/html,application/xhtml+xml,*/*;q=0.9",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"]      = "Mozilla/5.0 (compatible; AIG-Fetch/1.0)",
        },
        ssl_verify  = true,
        -- follow up to 3 redirects (request_uri does this automatically)
    })

    if err or not res then
        ngx.log(ngx.INFO, "fetch_url: request failed url=", url, " err=", tostring(err))
        return nil
    end

    if res.status >= 400 then
        ngx.log(ngx.INFO, "fetch_url: HTTP ", res.status, " url=", url)
        return nil
    end

    local ct = (res.headers and res.headers["Content-Type"]) or ""
    if not ct:match("html") and not ct:match("text") then
        -- Skip binary / non-text responses
        return nil
    end

    local text = html_to_text(res.body or "")
    if #text > MAX_CHARS then
        text = text:sub(1, MAX_CHARS) .. "…"
    end
    return text ~= "" and text or nil
end

-- Fetch up to n URLs in parallel (non-blocking via ngx.thread.spawn).
-- Returns array of {url=string, text=string|nil}.
function M.parallel(urls, n)
    n = math.min(n or 2, #urls)
    if n == 0 then return {} end

    if n == 1 then
        return {{ url = urls[1], text = M.fetch(urls[1]) }}
    end

    local threads = {}
    for i = 1, n do
        threads[i] = ngx.thread.spawn(M.fetch, urls[i])
    end

    local out = {}
    for i = 1, n do
        local ok, text = ngx.thread.wait(threads[i])
        out[i] = { url = urls[i], text = ok and text or nil }
        -- Kill any threads we haven't waited on yet if the wait errored
        if not ok and type(text) == "string" and text ~= "" then
            for j = i + 1, n do
                ngx.thread.kill(threads[j])
            end
            break
        end
    end
    return out
end

return M
