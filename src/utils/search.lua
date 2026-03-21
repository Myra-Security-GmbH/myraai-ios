-- utils/search.lua — async Brave web search
-- All HTTP via utils.http (cosocket, non-blocking).
-- Parallel queries use ngx.thread.spawn / ngx.thread.wait.

local http = require("utils.http")
local json = require("utils.json")

local M = {}

local BRAVE_URL = "https://api.search.brave.com/res/v1/web/search"

-- Fetch top-n results for one query.
-- Returns array of {title, url, snippet}; empty table on error.
function M.fetch(query, api_key, n)
    local status, _, body, err = http.request({
        method     = "GET",
        url        = BRAVE_URL .. "?q=" .. ngx.escape_uri(query)
                     .. "&count=" .. (n or 5),
        headers    = {
            ["Accept"]               = "application/json",
            ["X-Subscription-Token"] = api_key,
        },
        timeout_ms = 8000,
    })
    if err or status ~= 200 or not body then
        ngx.log(ngx.WARN, "search: brave fetch failed query=", query,
                " err=", tostring(err or status))
        return {}
    end
    local data    = json.decode(body) or {}
    local results = {}
    for _, r in ipairs((data.web or {}).results or {}) do
        results[#results + 1] = {
            title   = r.title       or "",
            url     = r.url         or "",
            snippet = r.description or "",
        }
    end
    return results
end

-- Strip HTML tags and decode common entities from a string.
local function strip_html(s)
    if not s then return "" end
    s = s:gsub("<[^>]+>", "")   -- remove tags
    s = s:gsub("&amp;",  "&")
    s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&#039;", "'")
    s = s:gsub("&nbsp;", " ")
    return s
end

-- Format a result array as a markdown text block.
local function format(results, query)
    if not results or #results == 0 then
        return "No results found for: " .. tostring(query)
    end
    local parts = {}
    for _, r in ipairs(results) do
        parts[#parts + 1] = "**" .. strip_html(r.title) .. "**\n"
                          .. r.url .. "\n"
                          .. strip_html(r.snippet)
    end
    return table.concat(parts, "\n\n")
end

-- Fetch results for multiple queries concurrently.
-- Returns array of formatted text strings, one per query.
-- Single query: no thread overhead.  Multiple: ngx.thread.spawn (non-blocking).
function M.parallel(queries, api_key, n)
    if #queries == 0 then return {} end
    if #queries == 1 then
        return { format(M.fetch(queries[1], api_key, n), queries[1]) }
    end
    local threads = {}
    for _, q in ipairs(queries) do
        threads[#threads + 1] = ngx.thread.spawn(M.fetch, q, api_key, n)
    end
    local out = {}
    for i, t in ipairs(threads) do
        local ok, res = ngx.thread.wait(t)
        out[i] = format(ok and res or {}, queries[i])
    end
    return out
end

return M
