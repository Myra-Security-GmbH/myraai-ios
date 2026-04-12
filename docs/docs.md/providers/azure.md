---
title: Azure OpenAI
description: How AI Gateway connects to Azure OpenAI, required gateway configuration, BYOK setup, and request examples.
---

# Azure OpenAI

Azure OpenAI uses the same wire format as OpenAI but requires routing to an Azure resource endpoint with deployment-specific paths and an `api-key` header. All configuration is set at the gateway level.

## Required gateway configuration

Three fields must be set in the gateway config before Azure requests will succeed:

| Field | Type | Default | Description |
|---|---|---|---|
| `azure_endpoint` | string | `null` | Your Azure OpenAI resource endpoint, e.g. `https://myresource.openai.azure.com` |
| `azure_deployment` | string | `null` | The deployment name created in Azure AI Studio. Overrides the `model` field in the request path. |
| `azure_api_version` | string | `"2024-02-01"` | API version appended as `?api-version=` query parameter |

> ⚠️ **Caution:** Requests to the Azure provider will fail with a configuration error if either `azure_endpoint` or `azure_deployment` is null. Ensure both are set before sending inference requests.

## Authentication

Azure uses an `api-key` header rather than a `Bearer` token. The gateway applies this automatically — store your Azure API key as the BYOK value and the gateway handles the header translation.

## Configuring Azure OpenAI

Before you begin, ensure the following conditions are met:
- ☑ You have an Azure OpenAI resource with at least one deployment created in Azure AI Studio.
- ☑ You have the Azure API key for the resource.
- ☑ The gateway exists and is accessible.

![Screenshot: Gateway configuration page with Azure fields visible](../assets/screenshots/gateway-config-azure.png)
*Azure OpenAI configuration fields on the gateway detail page.*

Proceed as follows to configure Azure OpenAI on a gateway:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Configuration** tab.
   - The configuration form opens.
4. Enter your Azure OpenAI resource endpoint in the **Azure endpoint** text field (for example, `https://myresource.openai.azure.com`).
   - The endpoint is set.
5. Enter your Azure deployment name in the **Azure deployment** text field.
   - The deployment is set.
6. Enter the API version in the **Azure API version** text field (for example, `2024-05-01-preview`).
   - The API version is set.
7. Click on the **Save** button.

→ The Azure configuration is saved.

To configure the gateway via the API:

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

## Adding an Azure API key

Before you begin, ensure the following conditions are met:
- ☑ The Azure OpenAI gateway configuration (endpoint, deployment, API version) is already saved.

Proceed as follows to add an Azure API key:

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Keys** tab.
   - The key management page opens.
4. Click on the **Add Key** button.
   - The key form opens.
5. Select `azure` from the **Provider** drop-down list.
   - The provider is set.
6. Enter `default` in the **Alias** text field.
   - The alias is set.
7. Enter your Azure API key in the **Key** text field.
   - The key value is set.
8. Click on the **Save** button.

→ The key is encrypted and stored. The gateway sends it as an `api-key` header to Azure.

To add the key via the API:

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

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/azure/chat/completions
```

### Compat endpoint

Route Azure requests via the compat endpoint by setting the `x-aig-provider` header explicitly. Azure model names are the same as OpenAI and would otherwise resolve to the OpenAI provider:

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/compat/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -H "x-aig-provider: azure" \
  -d '{"model": "gpt-4o", "messages": [...]}'
```

## Request example

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

## See also

- [Providers overview](overview.md)
- [OpenAI](openai.md)
- [Gateway configuration](../configuration/gateway-config.md)
