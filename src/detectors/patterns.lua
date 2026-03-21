-- detectors/patterns.lua
local M = {}

M.PATTERNS = {
    email          = "[a-zA-Z0-9%._%+%-]+@[a-zA-Z0-9%-%.]+%.[a-zA-Z][a-zA-Z]+",
    phone          = "%+?%d[%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-]",
    ssn            = "%d%d%d%-?%d%d%-?%d%d%d%d",
    dob            = "%d%d[%/-]%d%d[%/-]%d%d%d%d",
    ip_address     = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?",
    cc             = "%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d",
    cvv            = "[Cc][Vv][Vv2]?%s*:?%s*%d%d%d%d?",
    card_expiry    = "%d%d[%/%-]%d%d%d?%d?",
    iban           = "[A-Z][A-Z]%d%d%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%s?[A-Z0-9][A-Z0-9][A-Z0-9]?[A-Z0-9]?",
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
