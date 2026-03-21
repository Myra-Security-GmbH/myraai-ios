# Azure OpenAI

Azure OpenAI uses the same wire format as OpenAI but requires routing to an Azure resource endpoint with deployment-specific paths and an `api-key` header. All configuration is set at the gateway level.

---

## Required gateway config

Three fields must be set in the gateway config before Azure requests will succeed:

| Field | Type | Default | Description |
|---|---|---|---|
| `azure_endpoint` | string | `null` | Your Azure OpenAI resource endpoint, e.g. `https://myresource.openai.azure.com` |
| `azure_deployment` | string | `null` | The deployment name created in Azure AI Studio. Overrides the `model` field in the request path. |
| `azure_api_version` | string | `"2024-02-01"` | API version appended as `?api-version=` query parameter |

Set these with a PATCH request:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "azure_endpoint":    "https://myresource.openai.azure.com",
      "azure_deployment":  "gpt-4o-prod",
      "azure_api_version": "2024-05-01-preview"
    }
  }'
```

!!! warning "azure_endpoint and azure_deployment are required"
    Requests to the Azure provider will fail with a configuration error if either field is null. Ensure both are set before sending inference requests.

---

## Auth

Azure uses an `api-key` header rather than a `Bearer` token. The gateway applies this automatically — store your Azure API key as the BYOK value and the gateway handles the header translation.

---

## BYOK setup

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "azure",
    "alias": "default",
    "key": "<azure-api-key>"
  }'
```

---

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/azure/chat/completions
```

### Compat endpoint

You can also route Azure requests via the compat endpoint by setting the `x-aig-provider` header explicitly (Azure model names are the same as OpenAI and would otherwise resolve to the OpenAI provider):

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/compat/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -H "x-aig-provider: azure" \
  -d '{"model": "gpt-4o", "messages": [...]}'
```

---

## Full config + request example

```bash
# 1. Configure the gateway
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "azure_endpoint":    "https://contoso.openai.azure.com",
      "azure_deployment":  "gpt-4o-deployment",
      "azure_api_version": "2024-02-01"
    }
  }'

# 2. Store the Azure API key
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "azure",
    "alias": "default",
    "key": "abcdef1234567890abcdef1234567890"
  }'

# 3. Make an inference request
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/azure/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Summarize the benefits of Azure OpenAI."}],
    "max_tokens": 256
  }'
```

The gateway constructs the upstream URL as:

```
{azure_endpoint}/openai/deployments/{azure_deployment}/chat/completions?api-version={azure_api_version}
```

The `model` field in the request body is ignored for routing — `azure_deployment` from the config determines the actual model served.

---

## See also

- [Providers Overview](overview.md)
- [OpenAI](openai.md)
- [Gateway Configuration](../configuration/gateway-config.md)
