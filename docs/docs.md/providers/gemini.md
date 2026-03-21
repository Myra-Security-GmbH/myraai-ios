# Google Gemini

The gateway translates OpenAI chat completions format to the Google GenerateContent API (used by both Google AI Studio and Vertex AI) and translates responses back.

---

## Request translation

| OpenAI field | Gemini field | Notes |
|---|---|---|
| `messages[].role: "system"` | `system_instruction.parts[].text` | Extracted and placed in the top-level system instruction |
| `messages[].role: "user"` | `contents[].role: "user"` | |
| `messages[].role: "assistant"` | `contents[].role: "model"` | Role name translated |
| `max_tokens` | `generationConfig.maxOutputTokens` | |
| `temperature` | `generationConfig.temperature` | |
| `stream` | `?alt=sse` query param | SSE pass-through |

System messages are extracted from the messages array and passed as the `system_instruction` top-level object.

---

## BYOK setup (Google AI Studio)

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "gemini",
    "alias": "default",
    "key": "AIza..."
  }'
```

The key is sent as a Bearer token in the `Authorization` header to the Google AI API.

---

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/gemini/chat/completions
```

### Compat endpoint

The compat endpoint routes to Gemini for any model whose name starts with `gemini-`:

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

with `"model": "gemini-2.0-flash"`.

---

## Request example

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/gemini/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [
      {"role": "system", "content": "Reply only in haiku form."},
      {"role": "user",   "content": "Describe a sunset."}
    ],
    "max_tokens": 128,
    "temperature": 1.0
  }'
```

---

## Vertex AI variant

Vertex AI uses the same GenerateContent wire format but requires OAuth2 credentials and project/region configuration. Set the following fields in your gateway config:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "vertex_project": "my-gcp-project-id",
      "vertex_region":  "us-central1"
    }
  }'
```

| Config field | Default | Description |
|---|---|---|
| `vertex_project` | `null` | Google Cloud project ID (required for Vertex AI) |
| `vertex_region` | `"us-central1"` | Google Cloud region for Vertex AI endpoint |

### BYOK setup (Vertex AI)

For Vertex AI, store your OAuth2 access token (or a service account key JSON encoded as the key value):

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "vertex",
    "alias": "default",
    "key": "ya29...."
  }'
```

The gateway sends the key as an `x-goog-api-key` header to the Vertex AI endpoint.

### Vertex AI request example

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/vertex/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "gemini-2.0-flash",
    "messages": [{"role": "user", "content": "Hello from Vertex AI"}],
    "max_tokens": 256
  }'
```

!!! note "Project and region are required"
    Requests to the Vertex AI provider will fail with a configuration error if `vertex_project` is not set in the gateway config.

---

## See also

- [Providers Overview](overview.md)
- [Gateway Configuration](../configuration/gateway-config.md) — `vertex_project`, `vertex_region`
