# OpenAI

OpenAI is the native wire format for the AI Gateway. Requests are forwarded to `api.openai.com` without any translation — the gateway adds auth, logging, caching, and routing on top of a direct pass-through.

---

## How it works

Because the gateway uses the OpenAI request/response format internally, OpenAI requests require no translation. The request body is forwarded as-is; the response body is forwarded as-is. All standard gateway features (caching, retries, logging, detectors, rate limiting) still apply.

---

## BYOK setup

Store your OpenAI API key against the gateway:

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "alias": "default",
    "key": "sk-..."
  }'
```

The key is encrypted with AES-256-CBC before being written to the database. The plaintext is never persisted.

You can store multiple keys under different aliases and select among them per-request using the `x-aig-byok-alias` header.

---

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/openai/chat/completions
```

### Compat endpoint

The compat endpoint routes to OpenAI for any model whose name starts with `gpt-`, `o1-`, or `o3-`:

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

with `"model": "gpt-4o"` (or any other OpenAI model name).

---

## Request example

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/openai/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "gpt-4o",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "Explain LLM quantisation in one paragraph."}
    ],
    "temperature": 0.7,
    "max_tokens": 512
  }'
```

### Streaming

Add `"stream": true` to receive server-sent events:

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/openai/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Count to 5."}],
    "stream": true
  }'
```

The gateway passes SSE chunks through unchanged. A usage chunk is emitted just before the `[DONE]` event.

---

## Model selection

There is no hardcoded model list. Pass any valid OpenAI model name and it is forwarded verbatim. Examples:

| Model name | Description |
|---|---|
| `gpt-4o` | Latest GPT-4o multimodal |
| `gpt-4o-mini` | Smaller, faster, cheaper GPT-4o variant |
| `o3-mini` | Reasoning model |
| `gpt-4-turbo` | GPT-4 Turbo |

!!! note "Model availability"
    Available models depend on your OpenAI account tier. The gateway does not validate model names — an invalid name results in a 404 from OpenAI which is returned as-is.

---

## See also

- [Providers Overview](overview.md)
- [Azure OpenAI](azure.md) — for Azure-hosted OpenAI deployments
- [OpenAI-Compatible Providers](openai-compatible.md)
- [Gateway Configuration](../configuration/gateway-config.md)
