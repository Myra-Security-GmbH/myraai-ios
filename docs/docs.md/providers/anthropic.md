# Anthropic

The gateway translates OpenAI chat completions format to the Anthropic Messages API and translates responses back. You send a standard OpenAI-shaped request; the gateway handles all protocol differences.

---

## Request translation

| OpenAI field | Anthropic field | Notes |
|---|---|---|
| `messages[].role: "system"` | `system` (top-level string) | All consecutive system messages are joined with a newline and placed in the top-level `system` field |
| `messages[].role: "user"` | `messages[].role: "user"` | Content forwarded as-is |
| `messages[].role: "assistant"` | `messages[].role: "assistant"` | Content forwarded as-is |
| `max_tokens` | `max_tokens` | Direct mapping |
| `temperature` | `temperature` | Direct mapping |
| `stream` | `stream` | SSE pass-through |

System messages are extracted from the `messages` array and passed as the top-level `system` string. The remaining messages are forwarded in order.

---

## BYOK setup

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "anthropic",
    "alias": "default",
    "key": "sk-ant-..."
  }'
```

---

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/anthropic/chat/completions
```

### Compat endpoint

The compat endpoint routes to Anthropic for any model whose name starts with `claude-`:

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

with `"model": "claude-opus-4-6"`.

---

## Request example

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/anthropic/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "claude-opus-4-6",
    "messages": [
      {"role": "system",    "content": "You are a concise technical writer."},
      {"role": "user",      "content": "What is the difference between TCP and UDP?"}
    ],
    "max_tokens": 512,
    "temperature": 0.5
  }'
```

---

## Extended thinking

Anthropic's interleaved thinking feature exposes the model's reasoning steps in the response. Enable it by passing the beta header via the provider pass-through mechanism:

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/anthropic/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -H "x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14" \
  -d '{
    "model": "claude-opus-4-6",
    "messages": [{"role": "user", "content": "Solve: 17 × 23 + 144 ÷ 12"}],
    "max_tokens": 1024
  }'
```

The gateway strips the `x-aig-provider-` prefix and forwards `anthropic-beta: interleaved-thinking-2025-05-14` to Anthropic. Thinking blocks appear in the response content array alongside the final text block.

!!! note "Beta header format"
    Use `x-aig-provider-anthropic-beta` for any Anthropic beta feature. Multiple beta flags can be passed as a comma-separated value following Anthropic's header convention.

---

## Prompt caching

Anthropic supports caching portions of the prompt to reduce cost and latency on repeated requests with long shared context. When prompt caching is active the response `usage` object includes two additional fields:

| Field | Description |
|---|---|
| `cache_creation_tokens` | Tokens written to the cache on this request |
| `cache_read_tokens` | Tokens read from the cache (not re-processed) |

These fields are recorded in the request log alongside `input_tokens` and `output_tokens`.

### Cache pricing

Cache pricing differs from standard input pricing. The gateway records `cost_usd` using these rates when cache token counts are present in the response.

| Token type | Relative price |
|---|---|
| Standard input | 1× |
| Cache write | 1.25× input |
| Cache read | 0.1× input |

---

## See also

- [Providers Overview](overview.md)
- [Request Logging](../observability/logging.md) — cache token fields in logs
- [Gateway Configuration](../configuration/gateway-config.md)
