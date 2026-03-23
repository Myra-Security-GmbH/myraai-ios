-- guardrails/json_schema.lua — Tier 1 response-phase JSON schema validator
-- Validates that the LLM response content is valid JSON conforming to a
-- declared schema. Runs on the response phase only.
--
-- Supported schema constraints:
--   required[]                  — required top-level field names
--   properties[key].type        — string | number | boolean | array | object | null
--   properties[key].min         — minimum value (numbers)
--   properties[key].max         — maximum value (numbers)
--   properties[key].min_length  — minimum string length
--   properties[key].max_length  — maximum string length
--   properties[key].enum        — list of allowed values
--
-- Block reasons: json_parse_error | missing_field:<name> |
--                type_mismatch:<name> | range_violation:<name>

local cjson = require("cjson.safe")

local M = {}

-- Extract LLM content text from a raw response body (OpenAI-compatible format).
-- Falls back to Anthropic native format, then returns nil if unparseable.
local function extract_content(body)
    local ok, resp = pcall(cjson.decode, body)
    if not ok or type(resp) ~= "table" then return nil end
    -- OpenAI / compatible
    local choices = resp.choices
    if choices and choices[1] then
        local msg = choices[1].message
        if msg and type(msg.content) == "string" then return msg.content end
        local delta = choices[1].delta
        if delta and type(delta.content) == "string" then return delta.content end
    end
    -- Anthropic native
    local content = resp.content
    if content and content[1] and type(content[1].text) == "string" then
        return content[1].text
    end
    return nil
end

-- Strip markdown code fences (```json ... ``` etc.) before JSON parsing.
local function strip_fences(text)
    local inner = text:match("^%s*```[%w]*%s*\n?(.-)\n?```%s*$")
    return inner or text
end

-- Map a Lua value to the schema type name used in constraints.
local function value_type(v)
    if v == cjson.null then return "null" end
    local t = type(v)
    if t == "number"  then return "number"  end
    if t == "boolean" then return "boolean" end
    if t == "string"  then return "string"  end
    if t == "table" then
        -- Arrays in cjson carry array_mt; also check numeric key heuristic.
        if getmetatable(v) == cjson.array_mt or v[1] ~= nil then return "array" end
        return "object"
    end
    return t
end

local function verdict(action, pattern)
    if action == "block" then
        return { verdict = "block", pattern = pattern }
    else
        return { verdict = "flagged", pattern = pattern }
    end
end

function M.run(ctx, detector, phase)
    if phase ~= "response" then
        return { verdict = "pass" }
    end

    local body = ctx.response_body
    if not body or body == "" then return { verdict = "pass" } end

    local schema = detector.schema
    if not schema then return { verdict = "pass" } end

    local action = detector.action or "block"

    local content = extract_content(body)
    if not content then return { verdict = "pass" } end

    local cleaned = strip_fences(content)

    local ok, data = pcall(cjson.decode, cleaned)
    if not ok or data == nil or type(data) ~= "table" then
        return verdict(action, "json_parse_error")
    end

    -- Check required fields
    for _, field in ipairs(schema.required or {}) do
        if data[field] == nil then
            return verdict(action, "missing_field:" .. field)
        end
    end

    -- Check property constraints
    for field, c in pairs(schema.properties or {}) do
        local val = data[field]
        if val ~= nil then
            if c.type and value_type(val) ~= c.type then
                return verdict(action, "type_mismatch:" .. field)
            end
            if type(val) == "number" then
                if c.min ~= nil and val < c.min then return verdict(action, "range_violation:" .. field) end
                if c.max ~= nil and val > c.max then return verdict(action, "range_violation:" .. field) end
            end
            if type(val) == "string" then
                if c.min_length ~= nil and #val < c.min_length then return verdict(action, "range_violation:" .. field) end
                if c.max_length ~= nil and #val > c.max_length then return verdict(action, "range_violation:" .. field) end
            end
            if c.enum then
                local found = false
                for _, allowed in ipairs(c.enum) do
                    if val == allowed then found = true; break end
                end
                if not found then return verdict(action, "range_violation:" .. field) end
            end
        end
    end

    return { verdict = "pass" }
end

return M
