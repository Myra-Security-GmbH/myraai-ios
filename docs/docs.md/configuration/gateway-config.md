# Gateway Configuration

Every gateway has a `config` object that controls caching, timeouts, security, routing, and provider-specific settings. You update it with a single `PATCH` request — only the fields you include are changed.

## Updating gateway config

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "retry_count": 3,
      "timeout_ms": 30000,
      "log_payloads": false
    }
  }'
```

!!! note
    The `config` field is merged at the top level. Nested objects (such as `rate_limit`) are replaced in full when provided, not merged field-by-field.

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
| `detectors` | array | `[]` | Ordered list of detector configs (regex, keyword, pii, presidio, llm_guard). |
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
  "detectors": [],
  "azure_endpoint": null,
  "azure_deployment": null,
  "azure_api_version": "2024-02-01",
  "bedrock_region": "us-east-1",
  "vertex_project": null,
  "vertex_region": "us-central1",
  "provider_base_urls": {}
}
```

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

## See also

- [Rate Limiting](rate-limiting.md)
- [Budget & Quota Enforcement](budgets.md)
- [Detector Pipeline](../security/detectors.md)
- [Provider Key Management (BYOK)](../security/byok.md)
