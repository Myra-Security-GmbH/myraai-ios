-- detectors/presidio.lua — Tier 2 local Presidio sidecar detector
-- Analyzer: POST /analyze  to presidio-analyzer (default :5002)
-- Anonymizer: POST /anonymize to presidio-anonymizer (default :5001) for scrub action.
-- fail_open defaults to true: on sidecar error, pass the request through.

local json      = require("utils.json")
local http_util = require("utils.http")

local M = {}

local DEFAULT_ANALYZER_URL   = "http://127.0.0.1:5002"
local DEFAULT_ANONYMIZER_URL = "http://127.0.0.1:5001"
local DEFAULT_SCORE_THRESHOLD = 0.7
local DEFAULT_LANGUAGE        = "en"

-- Determine which body text to scan based on phase.
local function get_body(ctx, phase)
    if phase == "response" then
        return ctx.response_body
    else
        return ctx.raw_request_body
    end
end

-- Update the body in ctx based on phase.
local function set_body(ctx, phase, text)
    if phase == "response" then
        ctx.response_body = text
    else
        ctx.raw_request_body = text
    end
end

-- Call presidio-analyzer. Returns list of entity results or nil, err.
local function call_analyzer(text, detector)
    local url     = (detector.url or DEFAULT_ANALYZER_URL) .. "/analyze"
    local timeout = detector.timeout_ms or 3000

    local payload = json.encode({
        text            = text,
        language        = detector.language or DEFAULT_LANGUAGE,
        entities        = detector.entities,      -- nil → all entities
        score_threshold = detector.score_threshold or DEFAULT_SCORE_THRESHOLD,
    })

    local status, _, body, err = http_util.request({
        method     = "POST",
        url        = url,
        headers    = { ["Content-Type"] = "application/json" },
        body       = payload,
        timeout_ms = timeout,
    })

    if err or not body then
        return nil, "analyzer request: " .. tostring(err)
    end
    if status ~= 200 then
        return nil, "analyzer http " .. tostring(status)
    end

    local result = json.decode(body)
    if not result then
        return nil, "analyzer parse_response"
    end
    return result
end

-- Call presidio-anonymizer. Returns anonymized text or nil, err.
local function call_anonymizer(text, analyzer_results, detector)
    local url     = (detector.anonymizer_url or DEFAULT_ANONYMIZER_URL) .. "/anonymize"
    local timeout = detector.timeout_ms or 3000

    local payload = json.encode({
        text             = text,
        analyzer_results = analyzer_results,
    })

    local status, _, body, err = http_util.request({
        method     = "POST",
        url        = url,
        headers    = { ["Content-Type"] = "application/json" },
        body       = payload,
        timeout_ms = timeout,
    })

    if err or not body then
        return nil, "anonymizer request: " .. tostring(err)
    end
    if status ~= 200 then
        return nil, "anonymizer http " .. tostring(status)
    end

    local result = json.decode(body)
    if not result then
        return nil, "anonymizer parse_response"
    end
    return result.text
end

-- Collect unique entity_type values from analyzer results (for block_reason string).
local function collect_types(entities)
    local seen, types = {}, {}
    for _, e in ipairs(entities) do
        local et = e.entity_type or e.type
        if et and not seen[et] then
            seen[et] = true
            types[#types + 1] = et
        end
    end
    return table.concat(types, ",")
end

-- Build a structured list and a one-line summary for logging.
-- Returns detail_list, summary_string.
-- detail_list entries: {entity_type, start, ["end"], score}
-- Does NOT include the matched text to avoid writing PII into logs.
local function build_entity_detail(entities)
    local detail = {}
    local parts  = {}
    for _, e in ipairs(entities) do
        local et    = e.entity_type or e.type or "?"
        local s     = e.start  or 0
        local en    = e["end"] or 0
        local score = e.score  or 0
        detail[#detail + 1] = {
            entity_type = et,
            start       = s,
            ["end"]     = en,
            score       = math.floor(score * 100) / 100,
        }
        parts[#parts + 1] = string.format("%s@%d-%d(%.2f)", et, s, en, score)
    end
    return detail, table.concat(parts, ", ")
end

function M.run(ctx, detector, phase)
    local text = get_body(ctx, phase)
    if not text or text == "" then
        return { verdict = "pass" }
    end

    local action    = detector.action or "flag"
    local fail_open = detector.fail_open
    if fail_open == nil then fail_open = true end

    -- Step 1: analyze
    local entities, err = call_analyzer(text, detector)
    if not entities then
        ngx.log(ngx.WARN, "presidio: analyzer error: ", err)
        if fail_open then
            return { verdict = "pass" }
        else
            return { verdict = "block", pattern = "presidio_error" }
        end
    end

    -- No entities found → pass
    if #entities == 0 then
        return { verdict = "pass" }
    end

    local entity_types         = collect_types(entities)
    local entity_detail, summary = build_entity_detail(entities)

    if action == "scrub" then
        -- Step 2: anonymize
        local anonymized, anon_err = call_anonymizer(text, entities, detector)
        if not anonymized then
            ngx.log(ngx.WARN, "presidio: anonymizer error: ", anon_err)
            if fail_open then
                return { verdict = "pass" }
            else
                ngx.log(ngx.WARN, "presidio: blocking — ", summary)
                return { verdict = "block", pattern = entity_types, entities = entity_detail }
            end
        end
        set_body(ctx, phase, anonymized)
        return { verdict = "scrubbed", pattern = entity_types, entities = entity_detail }
    elseif action == "block" then
        ngx.log(ngx.WARN, "presidio: blocking — ", summary)
        return { verdict = "block", pattern = entity_types, entities = entity_detail }
    else
        -- flag (default)
        ngx.log(ngx.INFO, "presidio: flagged — ", summary)
        return { verdict = "flagged", pattern = entity_types, entities = entity_detail }
    end
end

return M
