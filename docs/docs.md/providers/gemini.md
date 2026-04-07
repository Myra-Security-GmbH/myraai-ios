---
title: Google Gemini
description: How AI Gateway translates OpenAI format to the Google GenerateContent API for both Google AI Studio and Vertex AI.
---

# Google Gemini

AI Gateway by Myra Security translates the OpenAI chat completions format to the Google GenerateContent API (used by both Google AI Studio and Vertex AI) and translates responses back.

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

## Adding a Google AI Studio API key

The gateway stores API keys using a bring-your-own-key (BYOK) mechanism. The key is sent as a Bearer token in the `Authorization` header to the Google AI API.

Before you begin, ensure the following conditions are met:
- ☑ You have a Google AI Studio API key (starting with `AIza`).
- ☑ The gateway exists and is accessible.

![Screenshot: BYOK key management page with Add Key form](../assets/screenshots/byok-add-key.png)
*The key management page for a gateway.*

► Proceed as follows to add a Google AI Studio API key:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Keys** tab.
   - The key management page opens.
4. Click on the **Add Key** button.
   - The key form opens.
5. Select `gemini` from the **Provider** drop-down list.
   - The provider is set.
6. Enter `default` in the **Alias** text field (or a custom alias if you store multiple keys).
   - The alias is set.
7. Enter your Google AI Studio API key (starting with `AIza`) in the **Key** text field.
   - The key value is set.
8. Click on the **Save** button.

→ The provider key is encrypted and stored. The gateway uses it for all Gemini requests on this gateway.

To add the key via the API:

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

## Vertex AI variant

Vertex AI uses the same GenerateContent wire format but requires OAuth2 credentials and project/region configuration.

### Configuring Vertex AI

Before you begin, ensure the following conditions are met:
- ☑ You have a Google Cloud project ID with the Vertex AI API enabled.
- ☑ You have a valid OAuth2 access token or service account key.

![Screenshot: Gateway configuration page with Vertex AI fields](../assets/screenshots/gateway-config-vertex.png)
*Vertex AI configuration fields on the gateway detail page.*

► Proceed as follows to configure the Vertex AI variant:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Configuration** tab.
   - The configuration form opens.
4. Enter your Google Cloud project ID in the **Vertex project** text field.
   - The project is set.
5. Enter the Google Cloud region in the **Vertex region** text field (for example, `us-central1`).
   - The region is set.
6. Click on the **Save** button.

→ The Vertex AI configuration is saved.

To configure Vertex AI via the API:

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

> 💡 **Note:** Requests to the Vertex AI provider will fail with a configuration error if `vertex_project` is not set in the gateway config.

Next, store your Vertex AI credentials as a BYOK key. For Vertex AI, store your OAuth2 access token (or a service account key JSON encoded as the key value):

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

## See also

- [Providers overview](overview.md)
- [Gateway configuration](../configuration/gateway-config.md) — `vertex_project`, `vertex_region`
