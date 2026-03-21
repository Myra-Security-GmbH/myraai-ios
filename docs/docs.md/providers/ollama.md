# Ollama (Local Inference)

Ollama runs open-weight models locally. The gateway forwards requests to an Ollama instance over HTTP with no API key required.

---

## How it works

Ollama exposes an OpenAI-compatible `/api/chat` endpoint. The gateway strips the `ollama/` namespace prefix from the model name before forwarding, so you can use a consistent `ollama/<model>` naming convention in your application.

**Model name translation example:**

| Request model name | Forwarded to Ollama as |
|---|---|
| `ollama/llama3.2` | `llama3.2` |
| `ollama/mistral` | `mistral` |
| `ollama/qwen2.5:14b` | `qwen2.5:14b` |

---

## Configuration

Set the Ollama base URL in your gateway config. The default is `http://localhost:11434`.

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

---

## No API key required

Ollama does not use API keys. Do not store a BYOK key for this provider. If the gateway's `auth_required` is `false` (common for local dev), no headers are required at all:

```bash
curl -s -X POST \
  "https://<your-gateway-host>/v1/myapp/local/ollama/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ollama/llama3.2",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

!!! note "auth_required for local dev"
    For purely local development you can set `"auth_required": false` in the gateway config to avoid needing auth tokens. Do not use this setting in any internet-accessible deployment.

---

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

---

## Request example

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

---

## Prerequisites

Ollama must be installed and the target model pulled before making requests:

```bash
# Install Ollama (Linux)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2
ollama pull mistral
ollama pull qwen2.5:14b
```

!!! warning "Model must be pulled first"
    If the model is not pulled, Ollama returns a 404 which the gateway surfaces as-is. Run `ollama list` to see available models.

---

## See also

- [Providers Overview](overview.md)
- [Gateway Configuration](../configuration/gateway-config.md) — `provider_base_urls`
- [Quick Start](../getting-started/quick-start.md)
