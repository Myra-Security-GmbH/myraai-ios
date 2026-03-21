-- guardrails/patterns.lua
local M = {}

M.PATTERNS = {
    email          = "[a-zA-Z0-9%._%+%-]+@[a-zA-Z0-9%-%.]+%.[a-zA-Z][a-zA-Z]+",
    -- Word-boundary anchor (%f[%d]) prevents matching digits embedded in longer
    -- numeric strings (e.g. serial numbers, version strings).
    phone          = "%f[%d]%+?%d[%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-]",
    ssn            = "%f[%d]%d%d%d%-?%d%d%-?%d%d%d%d%f[%D]",
    -- Year restricted to 1xxx or 2xxx to avoid matching arbitrary dates.
    dob            = "%d%d[%/-]%d%d[%/-][12]%d%d%d",
    ip_address     = "%f[%d]%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?",
    cc             = "%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d",
    cvv            = "[Cc][Vv][Vv2]?%s*:?%s*%d%d%d%d?",
    -- 2-digit year only (MM/YY). Restricting to 2-digit year avoids matching
    -- year ranges like "1986-1990" which previously triggered as false positives.
    -- Use a custom_pattern if you need to catch MM/YYYY format.
    card_expiry    = "%d%d[%/%-]%d%d%f[%D]",
    iban           = "[A-Z][A-Z]%d%d%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?",
    -- routing_number uses ABA checksum gating in regex.lua (see aba_check below).
    routing_number = "%f[%d]%d%d%d%d%d%d%d%d%d%f[%D]",
    mrn            = "[Mm][Rr][Nn]%s*:?%s*%d%d%d%d%d%d?%d?%d?",
    npi            = "%f[%d]%d%d%d%d%d%d%d%d%d%d%f[%D]",
    national_id    = "[A-Z]%d%d%d%d%d%d%d%d[A-Z]",
    passport_number= "[A-Z][A-Z]?%d%d%d%d%d%d%d",
    api_key        = "[Aa][Pp][Ii][_%-]?[Kk][Ee][Yy][\"'%s]*[:=][\"'%s]*[%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_]+",
    jwt            = "ey[A-Za-z0-9%-_]+%.[A-Za-z0-9%-_]+%.[A-Za-z0-9%-_]+",
}

M.SETS = {
    pci_pan          = { "cc", "cvv", "card_expiry", "iban", "routing_number" },
    hipaa_structured = { "ssn", "mrn", "npi", "dob", "phone", "email", "ip_address" },
    gdpr_structured  = { "email", "phone", "ip_address", "iban", "national_id", "passport_number" },
    credentials      = { "api_key", "jwt" },
    pii_basic        = { "email", "phone", "ssn" },
}

-- ABA routing number checksum (Federal Reserve algorithm).
-- 3*(d1+d4+d7) + 7*(d2+d5+d8) + (d3+d6+d9) must be divisible by 10.
-- Strips non-digit characters before checking.
function M.aba_check(s)
    s = s:gsub("%D", "")
    if #s ~= 9 then return false end
    local d = {}
    for i = 1, 9 do d[i] = tonumber(s:sub(i, i)) end
    local sum = 3*(d[1]+d[4]+d[7]) + 7*(d[2]+d[5]+d[8]) + (d[3]+d[6]+d[9])
    return sum % 10 == 0
end

function M.luhn_check(s)
    s = s:gsub("[%s%-]", "")
    if not s:match("^%d+$") then return false end
    local n = #s
    if n < 13 or n > 19 then return false end
    local sum = 0
    for i = 1, n do
        local d = tonumber(s:sub(i, i))
        if (n - i) % 2 == 1 then
            d = d * 2
            if d > 9 then d = d - 9 end
        end
        sum = sum + d
    end
    return sum % 10 == 0
end

function M.resolve(names)
    local result, seen = {}, {}
    for _, name in ipairs(names or {}) do
        local set = M.SETS[name]
        if set then
            for _, pname in ipairs(set) do
                if not seen[pname] and M.PATTERNS[pname] then
                    seen[pname] = true
                    result[#result + 1] = { name = pname, pattern = M.PATTERNS[pname] }
                end
            end
        elseif M.PATTERNS[name] and not seen[name] then
            seen[name] = true
            result[#result + 1] = { name = name, pattern = M.PATTERNS[name] }
        end
    end
    return result
end

return M
