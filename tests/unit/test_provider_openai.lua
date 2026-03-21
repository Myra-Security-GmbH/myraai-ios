-- tests/unit/test_provider_openai.lua
-- Run with: busted tests/unit/test_provider_openai.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = { http_x_request_id = "" },
    req    = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Clear stale mocks left by earlier test files in the same runner process
for _, n in ipairs({"providers.openai","utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

local openai = require("providers.openai")

describe("providers.openai", function()

    it("base_url uses OPENAI_BASE + provider_path", function()
        local ctx = {
            provider_path  = "/v1/chat/completions",
            gateway_config = {},
        }
        local url = openai.base_url(ctx)
        assert.equal("https://api.openai.com/v1/chat/completions", url)
    end)

    it("build_headers sets Authorization bearer", function()
        local ctx = {
            request_id     = "req-1",
            gateway_config = {},
        }
        local h = openai.build_headers(ctx, "sk-test")
        assert.equal("Bearer sk-test", h["Authorization"])
        assert.equal("application/json", h["Content-Type"])
    end)

    it("parse_response extracts content and tokens", function()
        local body = [[{
            "id": "chatcmpl-1",
            "choices": [{"message": {"role":"assistant","content":"Hello!"}, "finish_reason":"stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
        }]]
        local result, err = openai.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello!", result.content)
        assert.equal(10, result.input_tokens)
        assert.equal(5,  result.output_tokens)
    end)

    it("parse_response returns error for provider errors", function()
        local body = [[{"error": {"message": "invalid api key", "type": "auth_error"}}]]
        local result, err = openai.parse_response(body)
        assert.is_nil(result)
        assert.equal("invalid api key", err)
    end)

    it("parse_sse_chunk extracts delta text", function()
        local line = [[data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}]]
        local parsed = openai.parse_sse_chunk(line)
        assert.not_nil(parsed)
        assert.equal("Hi", parsed.delta)
        assert.is_false(parsed.done)
    end)

    it("parse_sse_chunk returns done=true for [DONE]", function()
        local parsed = openai.parse_sse_chunk("data: [DONE]")
        assert.not_nil(parsed)
        assert.is_true(parsed.done)
    end)

end)
