-- utils/thinking.lua — strip reasoning/thinking content from LLM stream deltas
--
-- Reasoning models (DeepSeek-R1, Qwen3, gpt-oss, etc.) emit chain-of-thought
-- either via a separate delta.reasoning field or inline as <think>…</think>
-- tags inside delta.content.  Neither should be forwarded to the end user.
--
-- M.strip(text, in_think) → visible_text, new_in_think
--   Stateful: call with the same in_think bool across chunks of one stream.
--   in_think starts as false for each new response.

local M = {}

-- Strip <think>…</think> blocks from one streaming delta chunk.
-- Returns: filtered_text, updated_in_think_state
-- Handles tags that span chunk boundaries via the persisted in_think flag.
function M.strip(text, in_think)
    if not text or text == "" then return text, in_think end
    local parts = {}
    local pos   = 1
    while pos <= #text do
        if in_think then
            local close = text:find("</think>", pos, true)
            if close then
                in_think = false
                pos = close + 8  -- skip past </think>
            else
                break            -- rest of chunk is reasoning — drop
            end
        else
            local open  = text:find("<think>",  pos, true)
            local close = text:find("</think>", pos, true)
            -- Orphan </think>: vLLM reasoning-parser mode puts thinking in
            -- delta.reasoning and emits </think> as a transition marker in
            -- delta.content.  Everything before (and including) </think> is
            -- leaked reasoning content — drop it.
            if close and (not open or close < open) then
                in_think = false
                pos = close + 8  -- skip past </think>
            elseif open then
                if open > pos then parts[#parts + 1] = text:sub(pos, open - 1) end
                in_think = true
                pos = open + 7  -- skip past <think>
            else
                parts[#parts + 1] = text:sub(pos)
                break
            end
        end
    end
    return table.concat(parts), in_think
end

return M
