-- middleware/guardrails_request.lua — block unsafe prompts
-- Config (in gateway_config.guardrails):
--   { enabled = true, block_categories = ["hate","self_harm","violence"] }
-- Phase 1 uses a keyword/regex classifier. Phase 2 can add an LLM classifier.

local errors = require("core.errors")
local json   = require("utils.json")

local M = {}

-- Keyword lists per category (extend as needed)
local CATEGORIES = {
    hate = {
        "\\bkill all\\b", "\\b(racial|ethnic) slur\\b",
    },
    self_harm = {
        "\\bhow to (commit suicide|self.harm)\\b",
        "\\bways to (hurt|kill) (my|your)?self\\b",
    },
    violence = {
        "\\bhow to (make|build) (a )?bomb\\b",
        "\\bstep.by.step.*?(murder|assassination)\\b",
    },
}

local function extract_prompt_text(body)
    if not body then return "" end
    -- OpenAI / compat messages array
    if body.messages then
        local parts = {}
        for _, msg in ipairs(body.messages) do
            if type(msg.content) == "string" then
                parts[#parts + 1] = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if part.type == "text" then
                        parts[#parts + 1] = part.text or ""
                    end
                end
            end
        end
        return table.concat(parts, "\n")
    end
    -- Anthropic prompt field
    if body.prompt then return body.prompt end
    return ""
end

function M.run(ctx)
    local gr = ctx.gateway_config.guardrails
    if not gr or not gr.enabled then return end

    local categories = gr.block_categories or {}
    if #categories == 0 then return end

    -- Parse body if not already done
    if not ctx.request_body then
        if not ctx.raw_request_body then
            ngx.req.read_body()
            ctx.raw_request_body = ngx.req.get_body_data() or ""
        end
        ctx.request_body = json.decode(ctx.raw_request_body) or {}
    end

    local text = extract_prompt_text(ctx.request_body):lower()

    for _, category in ipairs(categories) do
        local patterns = CATEGORIES[category]
        if patterns then
            for _, pat in ipairs(patterns) do
                if text:find(pat) then
                    ngx.log(ngx.WARN, "Guardrail block: category=", category,
                            " tenant=", ctx.tenant_id)
                    errors.send("GUARDRAIL_BLOCKED",
                        "Request blocked by content policy: " .. category)
                end
            end
        end
    end
end

return M
