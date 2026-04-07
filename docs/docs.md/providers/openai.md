---
title: OpenAI
description: How AI Gateway connects to OpenAI, endpoint configuration, BYOK setup, and request examples.
---

# OpenAI

OpenAI is the native wire format for AI Gateway by Myra Security. Requests are forwarded to `api.openai.com` without any translation — the gateway adds authentication, logging, caching, and routing on top of a direct pass-through.

## How it works

Because the gateway uses the OpenAI request/response format internally, OpenAI requests require no translation. The request body is forwarded as-is; the response body is forwarded as-is. All standard gateway features (caching, retries, logging, detectors, rate limiting) still apply.

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

## Adding an OpenAI API key

The gateway stores API keys using a bring-your-own-key (BYOK) mechanism. Keys are encrypted with AES-256-CBC before being written to the database. The plaintext is never persisted.

Before you begin, ensure the following conditions are met:
- ☑ You have an OpenAI API key (starting with `sk-`).
- ☑ The gateway exists and is accessible.

![Screenshot: BYOK key management page with Add Key form](../assets/screenshots/byok-add-key.png)
*The key management page for a gateway.*

► Proceed as follows to add an OpenAI provider key:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Keys** tab.
   - The key management page opens.
4. Click on the **Add Key** button.
   - The key form opens.
5. Select `openai` from the **Provider** drop-down list.
   - The provider is set.
6. Enter `default` in the **Alias** text field (or a custom alias if you store multiple keys).
   - The alias is set.
7. Enter your OpenAI API key (starting with `sk-`) in the **Key** text field.
   - The key value is set.
8. Click on the **Save** button.

→ The provider key is encrypted and stored. The gateway uses it for all OpenAI requests on this gateway.

To add the key via the API:

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

You can store multiple keys under different aliases and select among them per request using the `x-aig-byok-alias` header.

## Model selection

There is no hardcoded model list. Pass any valid OpenAI model name and it is forwarded verbatim. Examples:

| Model name | Description |
|---|---|
| `gpt-4o` | Latest GPT-4o multimodal |
| `gpt-4o-mini` | Smaller, faster, cheaper GPT-4o variant |
| `o3-mini` | Reasoning model |
| `gpt-4-turbo` | GPT-4 Turbo |

> 💡 **Note:** Available models depend on your OpenAI account tier. The gateway does not validate model names — an invalid name results in a 404 from OpenAI which is returned as-is.

## Request examples

### Standard request

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

The gateway passes server-sent event (SSE) chunks through unchanged. A usage chunk is emitted just before the `[DONE]` event.

## See also

- [Providers overview](overview.md)
- [Azure OpenAI](azure.md) — for Azure-hosted OpenAI deployments
- [OpenAI-compatible providers](openai-compatible.md)
- [Gateway configuration](../configuration/gateway-config.md)
