-- tests/unit/test_think_filter.lua
-- Unit tests for utils/thinking.lua (strip_think) and the reasoning-field
-- suppression in providers/openai parse_sse_chunk.

_G.ngx = {
    log = function() end,
    ERR = 0, WARN = 1, INFO = 2,
    req = { get_headers = function() return {} end },
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

for _, n in ipairs({"utils.thinking","providers.openai","utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

local thinking = require("utils.thinking")

-- ── thinking.strip ───────────────────────────────────────────────────────────

describe("thinking.strip — plain text (no think tags)", function()

    it("returns text unchanged when no tags present", function()
        local out, state = thinking.strip("Hello world", false)
        assert.equal("Hello world", out)
        assert.is_false(state)
    end)

    it("empty string returns empty string", function()
        local out, state = thinking.strip("", false)
        assert.equal("", out)
        assert.is_false(state)
    end)

    it("nil returns nil", function()
        local out, state = thinking.strip(nil, false)
        assert.is_nil(out)
        assert.is_false(state)
    end)

end)

describe("thinking.strip — complete <think> block in one chunk", function()

    it("strips block at the start, keeps tail", function()
        local out, state = thinking.strip("<think>reasoning</think>Answer", false)
        assert.equal("Answer", out)
        assert.is_false(state)
    end)

    it("strips block in the middle", function()
        local out, state = thinking.strip("A<think>hidden</think>B", false)
        assert.equal("AB", out)
        assert.is_false(state)
    end)

    it("strips block at the end with no tail", function()
        local out, state = thinking.strip("Prefix<think>hidden</think>", false)
        assert.equal("Prefix", out)
        assert.is_false(state)
    end)

    it("strips block that is the entire chunk", function()
        local out, state = thinking.strip("<think>only reasoning</think>", false)
        assert.equal("", out)
        assert.is_false(state)
    end)

    it("strips two consecutive blocks", function()
        local out, state = thinking.strip("<think>x</think>A<think>y</think>B", false)
        assert.equal("AB", out)
        assert.is_false(state)
    end)

end)

describe("thinking.strip — think block spanning multiple chunks", function()

    it("chunk opens <think>: returns empty, state=true", function()
        local out, state = thinking.strip("Before<think>start of reasoning", false)
        assert.equal("Before", out)
        assert.is_true(state, "should be in_think=true after unclosed tag")
    end)

    it("middle chunk while in_think=true: returns empty, state stays true", function()
        local out, state = thinking.strip("still reasoning text", true)
        assert.equal("", out)
        assert.is_true(state)
    end)

    it("closing chunk with </think>: drops reasoning, returns tail", function()
        local out, state = thinking.strip("</think>visible answer", true)
        assert.equal("visible answer", out)
        assert.is_false(state)
    end)

    it("full three-chunk scenario produces only visible content", function()
        local s1, st1 = thinking.strip("<think>", false)
        local s2, st2 = thinking.strip("reasoning here", st1)
        local s3, st3 = thinking.strip("</think>Answer", st2)
        assert.equal("", s1)
        assert.equal("", s2)
        assert.equal("Answer", s3)
        assert.is_false(st3)
    end)

    it("prefix before <think> is preserved across chunk boundary", function()
        local s1, st1 = thinking.strip("Hello <think>think", false)
        assert.equal("Hello ", s1)
        assert.is_true(st1)
        local s2, st2 = thinking.strip("</think> World", st1)
        assert.equal(" World", s2)
        assert.is_false(st2)
    end)

end)

-- ── parse_sse_chunk: reasoning field suppression ─────────────────────────────

describe("openai parse_sse_chunk — delta.reasoning suppression", function()
    local openai = require("providers.openai")

    -- delta.reasoning is always ignored. Answer arrives in delta.content.

    it("reasoning chunk yields empty delta", function()
        local line = [[data: {"choices":[{"delta":{"content":"","reasoning":"We need to think..."},"finish_reason":null}]}]]
        local p = openai.parse_sse_chunk(line)
        assert.equal("", p.delta)
    end)

    it("answer chunk (delta.content populated) is forwarded", function()
        local line = [[data: {"choices":[{"delta":{"content":"4"},"finish_reason":null}]}]]
        local p = openai.parse_sse_chunk(line)
        assert.equal("4", p.delta)
    end)

    it("delta.reasoning ignored even when delta.content is also present", function()
        local line = [[data: {"choices":[{"delta":{"content":"real","reasoning":"thinking"},"finish_reason":null}]}]]
        local p = openai.parse_sse_chunk(line)
        assert.equal("real", p.delta)
    end)

end)
