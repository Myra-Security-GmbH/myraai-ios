---
title: Anthropic
description: How AI Gateway translates OpenAI format to the Anthropic Messages API, including system message handling, prompt caching, and extended thinking.
---

# Anthropic

AI Gateway by Myra Security translates the OpenAI chat completions format to the Anthropic Messages API and translates responses back. You send a standard OpenAI-shaped request; the gateway handles all protocol differences.

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

## Adding an Anthropic API key

The gateway stores API keys using a bring-your-own-key (BYOK) mechanism. Keys are encrypted before being written to the database. The plaintext is never persisted.

Before you begin, ensure the following conditions are met:
- ☑ You have an Anthropic API key (starting with `sk-ant-`).
- ☑ The gateway exists and is accessible.

![Screenshot: BYOK key management page with Add Key form](../assets/screenshots/byok-add-key.png)
*The key management page for a gateway.*

Proceed as follows to add an Anthropic provider key:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Keys** tab.
   - The key management page opens.
4. Click on the **Add Key** button.
   - The key form opens.
5. Select `anthropic` from the **Provider** drop-down list.
   - The provider is set.
6. Enter `default` in the **Alias** text field (or a custom alias if you store multiple keys).
   - The alias is set.
7. Enter your Anthropic API key (starting with `sk-ant-`) in the **Key** text field.
   - The key value is set.
8. Click on the **Save** button.

→ The provider key is encrypted and stored. The gateway uses it for all Anthropic requests on this gateway.

To add the key via the API:

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

## Extended thinking

The interleaved thinking feature of Anthropic exposes the reasoning steps of the model in the response. Enable it by passing the beta header via the provider pass-through mechanism:

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

> 💡 **Note:** Use `x-aig-provider-anthropic-beta` for any Anthropic beta feature. Pass multiple beta flags as a comma-separated value following the header convention of Anthropic.

## Prompt caching

Anthropic supports caching portions of the prompt to reduce cost and latency on repeated requests with long shared context. When prompt caching is active, the response `usage` object includes two additional fields:

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

## Context compaction

Context compaction automatically summarises older conversation turns when the estimated input token count exceeds a configured threshold. Compaction keeps long conversations within model context limits and reduces the cost of each subsequent turn.

### How it works

Before forwarding a request to Anthropic, the gateway estimates the total input token count. When the estimate meets or exceeds the configured `threshold_tokens` value (default: 200 000) and Anthropic's minimum compaction threshold (50 000 tokens), the gateway injects the `compact-2026-01-12` beta header and a `context_management` field into the request body.

Anthropic's API then:

1. Summarises conversation turns older than the most recent `keep_last_turns` turns.
2. Replaces the verbatim history with the summary in subsequent turns.
3. Returns a `compaction` content block in the response alongside the assistant reply.

The gateway forwards a `aig_status:compacted` server-sent event to streaming clients when a compaction block is detected in the response stream. The number of tokens saved by compaction is available in the request log.

### Configuration

Context compaction is enabled by default for all gateways. To disable it for a specific gateway, set `context_compaction.enabled` to `false` in the gateway config.

| Field | Type | Default | Description |
|---|---|---|---|
| `context_compaction.enabled` | boolean | `true` | Enable or disable context compaction for this gateway. |
| `context_compaction.threshold_tokens` | integer | `200000` | Input token count that triggers compaction. Minimum: `50000`. |
| `context_compaction.keep_last_turns` | integer | `10` | Number of most recent user turns to keep verbatim. |

> 💡 **Note:** Context compaction applies only to Anthropic models. For all other providers, the setting is present in the config but has no effect.

> ⚠️ **Caution:** Compacted summaries are generated by the model and may omit details present in the original conversation. For workloads that require exact conversation replay (for example, legal or audit trails), disable context compaction.

See [Gateway Configuration Reference](../reference/config-reference.md#context-compaction) for the full field reference.

---

## See also

- [Providers overview](overview.md)
- [Request logging](../observability/logging.md) — cache token fields in logs
- [Gateway configuration](../configuration/gateway-config.md)
