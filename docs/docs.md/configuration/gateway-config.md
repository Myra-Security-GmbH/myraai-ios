# Gateway Configuration

Every gateway has a `config` object that controls caching, timeouts, security, routing, and provider-specific settings.

## Using the admin UI

1. Open **Gateways** in the left sidebar and click the gateway you want to configure.
2. Open the **Config** tab.
3. Edit any field and click **Save**. Only the fields you change are updated — other settings are unaffected.

## Config fields reference

| Field | Type | Default | Description |
|---|---|---|---|
| `cache_ttl` | integer | `0` | Response cache TTL in seconds. `0` disables caching. |
| `retry_count` | integer | `2` | Number of retry attempts against the primary provider on 5xx errors before moving to fallbacks. |
| `timeout_ms` | integer | `60000` | Per-request upstream timeout in milliseconds. |
| `log_payloads` | boolean | `true` | Whether to store request and response bodies in the log table. Disable for sensitive workloads. |
| `auth_required` | boolean | `true` | Require a valid auth token on every inference request. Set to `false` only for development. |
| `budget_usd` | number \| null | `null` | Monthly spend cap in USD for this gateway. `null` means no limit. Superseded by per-token budgets. |
| `rate_limit` | object \| null | `null` (disabled) | Gateway-level rate limit. Default: `null` (disabled). Example: `{"requests": 100, "window_sec": 60}`. Applied before per-token limits. |
| `ip_allowlist` | array | `[]` | List of CIDR blocks permitted to call this gateway. Empty list allows all sources. |
| `guardrails` | array | `[]` | Ordered list of guardrail configs (regex, keyword, presidio, prompt_guard, pii_protector). |
| `azure_endpoint` | string \| null | `null` | Azure OpenAI resource endpoint, e.g. `https://myresource.openai.azure.com`. |
| `azure_deployment` | string \| null | `null` | Azure deployment name. Overrides the model name in the request path. |
| `azure_api_version` | string | `"2024-02-01"` | Azure OpenAI API version query parameter. |
| `bedrock_region` | string | `"us-east-1"` | AWS region used for Bedrock requests. |
| `vertex_project` | string \| null | `null` | Google Cloud project ID for Vertex AI. |
| `vertex_region` | string | `"us-central1"` | Google Cloud region for Vertex AI. |
| `provider_base_urls` | object | `{}` | Map of `provider → base URL` for overriding default provider endpoints. |

## Full default config

```json
{
  "cache_ttl": 0,
  "retry_count": 2,
  "timeout_ms": 60000,
  "log_payloads": true,
  "auth_required": true,
  "budget_usd": null,
  "rate_limit": null,
  "ip_allowlist": [],
  "guardrails": [],
  "azure_endpoint": null,
  "azure_deployment": null,
  "azure_api_version": "2024-02-01",
  "bedrock_region": "us-east-1",
  "vertex_project": null,
  "vertex_region": "us-central1",
  "provider_base_urls": {}
}
```

## Provider Base URLs

The `provider_base_urls` field lets you override the default upstream endpoint for any provider on a per-gateway basis. This is useful for:

- **Local Ollama** — point the gateway at an Ollama instance running on a custom host or port
- **Private deployments** — route to an on-premises or VPC-hosted model server
- **Custom proxies** — send traffic through an intermediary before it reaches the provider

### In the admin UI

1. Open **Gateways** and click the gateway.
2. Open the **Config** tab.
3. Scroll to **Provider Base URLs** and click **Add**.
4. Enter the provider name (e.g. `ollama`) and the base URL (e.g. `http://192.168.1.50:11434`).
5. Click **Save**.

### Format

The value must be a bare `protocol://host:port` with no trailing slash or path. The gateway appends the provider's standard request path automatically.

### Examples

| Provider | Override value | When to use |
|---|---|---|
| `ollama` | `http://localhost:11434` | Ollama running locally on the default port |
| `ollama` | `http://192.168.1.50:11434` | Ollama on another machine in the same network |
| `openai` | `https://proxy.internal/openai` | Corporate proxy in front of the OpenAI API |
| `anthropic` | `http://localhost:4010` | Local mock server for integration tests |

Any of the 21 supported providers can be overridden. To remove an override, delete the entry and save.

## Per-request header overrides

Certain behaviors can be overridden on individual requests without changing the gateway config.

| Header | Type | Description |
|---|---|---|
| `x-aig-byok-alias` | string | Select a non-default BYOK key alias for this request. See [Provider Key Management](../security/byok.md). |
| `x-aig-meta-{key}` | string | Attach arbitrary metadata to the request log entry. Accessible as `meta.{key}` in routing rule conditions. |
| `x-aig-collect-log` | `"0"` or `"false"` to disable; `"1"` to enable | Override whether this request is written to the log table. Both `"0"` and `"false"` disable logging for this request. |
| `x-aig-collect-log-payload` | `"0"` or `"false"` to disable; `"1"` to enable | Override whether request/response bodies are stored for this request, independent of `log_payloads` config. Both `"0"` and `"false"` suppress body storage. |
| `x-aig-provider-{field}` | string | Override a provider-specific field for this request (e.g. `x-aig-provider-model`). |

!!! warning
    `x-aig-collect-log-payload: 0` suppresses body storage for that request only. It does not affect the gateway-level `log_payloads` setting for other requests.

## API

Gateway config can also be updated via the Admin API using a PATCH request. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) for endpoint reference and examples.

## See also

- [Rate Limiting](rate-limiting.md)
- [Budget & Quota Enforcement](budgets.md)
- [Guardrail Pipeline](../security/guardrails.md)
- [Provider Key Management (BYOK)](../security/byok.md)
