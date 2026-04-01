---
title: Ollama
description: How AI Gateway connects to a local or remote Ollama instance for open-weight model inference.
---

# Ollama

Ollama runs open-weight models locally. AI Gateway by Myra Security forwards requests to an Ollama instance over HTTP with no API key required.

## How it works

Ollama exposes an OpenAI-compatible `/api/chat` endpoint. The gateway strips the `ollama/` namespace prefix from the model name before forwarding, so you can use a consistent `ollama/<model>` naming convention in your application.

**Model name translation:**

| Request model name | Forwarded to Ollama as |
|---|---|
| `ollama/llama3.2` | `llama3.2` |
| `ollama/mistral` | `mistral` |
| `ollama/qwen2.5:14b` | `qwen2.5:14b` |

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/ollama/chat/completions
```

### Compat endpoint

Set the model with the `ollama/` prefix — the compat endpoint resolves it to the Ollama provider:

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

with `"model": "ollama/llama3.2"`.

## Prerequisites

Before you begin, ensure the following conditions are met:
- ☑ Ollama is installed and running on the target host.
- ☑ The required model has been pulled on the Ollama instance.
- ☑ The gateway exists and is accessible.

```bash
# Install Ollama (Linux)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2
ollama pull mistral
ollama pull qwen2.5:14b
```

Run `ollama list` to see locally available models.

## Configuring Ollama as a provider

![Screenshot: Gateway configuration page with provider base URLs section](../assets/screenshots/gateway-config-base-urls.png)
*The provider base URL configuration on the gateway detail page.*

► Proceed as follows to configure Ollama on a gateway:

1. Open **Gateways** in the left sidebar.
   ⇒ The gateway list opens.
2. Click on the gateway you want to configure.
   ⇒ The gateway detail page opens.
3. Click on the **Configuration** tab.
   ⇒ The configuration form opens.
4. Enter the Ollama base URL in the **Ollama base URL** text field (default: `http://localhost:11434`).
   ⇒ The base URL is set.
5. Click on the **Save** button.

→ The Ollama configuration is saved. The gateway routes Ollama requests to the specified host.

To configure via the API (local instance):

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "provider_base_urls": {
        "ollama": "http://localhost:11434"
      }
    }
  }'
```

To point to a remote Ollama instance:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "provider_base_urls": {
        "ollama": "http://192.168.1.50:11434"
      }
    }
  }'
```

## Authentication

Ollama does not use API keys. Do not store a BYOK key for this provider. If the `auth_required` setting of the gateway is `false` (common for local development), no headers are required at all:

```bash
curl -s -X POST \
  "https://<your-gateway-host>/v1/myapp/local/ollama/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ollama/llama3.2",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

> 💡 **Note:** For purely local development, set `"auth_required": false` in the gateway config to avoid needing auth tokens. Do not use this setting in any internet-accessible deployment.

## Request examples

### Standard request

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/ollama/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "ollama/llama3.2",
    "messages": [
      {"role": "system", "content": "You are a helpful coding assistant."},
      {"role": "user",   "content": "Write a Python function to flatten a nested list."}
    ],
    "temperature": 0.2,
    "max_tokens": 512
  }'
```

### Streaming

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/ollama/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "ollama/mistral",
    "messages": [{"role": "user", "content": "Explain Docker in plain English."}],
    "stream": true
  }'
```

## See also

- [Providers overview](overview.md)
- [Gateway configuration](../configuration/gateway-config.md) — `provider_base_urls`
- [Quick start](../getting-started/quick-start.md)
