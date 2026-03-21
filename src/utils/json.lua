-- utils/json.lua — cjson wrapper with safe error handling
local cjson = require("cjson.safe")
cjson.decode_array_with_array_mt(true)

local M = {}

-- cjson allows lone UTF-16 surrogates during decode, storing them as invalid
-- UTF-8 byte sequences (0xED [0xA0-0xBF] [0x80-0xBF]) in Lua strings, and
-- re-emits them verbatim on encode.  Strict parsers (Anthropic API, Python's
-- json module) reject such sequences.  sanitize_surrogates() replaces them
-- with U+FFFD (the Unicode replacement character) before forwarding to upstreams.
--
-- Handles two representations:
--   1. Raw invalid UTF-8 bytes  0xED [0xA0-0xBF] [0x80-0xBF]
--   2. JSON \uDxxx escape literals  (e.g. \uD83D without a paired \uDExxx)
local _surr_byte_pat = string.char(0xED)
    .. "[" .. string.char(0xA0) .. "-" .. string.char(0xBF) .. "]"
    .. "[" .. string.char(0x80) .. "-" .. string.char(0xBF) .. "]"
local _surr_esc_pat  = "\\u[Dd][89A-Fa-f]%x%x"   -- \uD800–\uDFFF as literal escapes (4 hex digits)
local _repl_bytes    = string.char(0xEF, 0xBF, 0xBD)  -- U+FFFD in UTF-8
local _repl_esc      = "\\ufffd"

function M.sanitize_surrogates(s)
    if type(s) ~= "string" then return s end
    s = s:gsub(_surr_byte_pat, _repl_bytes)
    s = s:gsub(_surr_esc_pat,  _repl_esc)
    return s
end

function M.encode(val)
    local ok, result = pcall(cjson.encode, val)
    if not ok then
        ngx.log(ngx.ERR, "json.encode error: ", result)
        return nil, result
    end
    return result
end

function M.decode(str)
    if not str or str == "" then return {} end
    local ok, result = pcall(cjson.decode, str)
    if not ok then
        ngx.log(ngx.ERR, "json.decode error: ", result, " input: ", str:sub(1, 200))
        return nil, result
    end
    return result
end

M.null = cjson.null

return M
