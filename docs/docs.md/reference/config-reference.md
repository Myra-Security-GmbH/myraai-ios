# Gateway Configuration Reference

Every gateway has a `config` JSON object that controls authentication, caching, timeouts, security, routing, and provider settings. Update it with `PATCH /admin/v1/gateways/{id}`.

The config is **merged at the top level** on each PATCH — only the fields you include are changed. Nested objects (`rate_limit`) are replaced in full when provided.

---

## Full default config

```json
{
  "auth_required": true,
  "budget_usd": null,
  "cache_ttl": 0,
  "retry_count": 2,
  "timeout_ms": 60000,
  "log_payloads": true,
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

---

## Core fields

| Field | Type | Default | Description |
|---|---|---|---|
| `auth_required` | boolean | `true` | Require a valid `x-aig-token`, `Authorization: Bearer`, or `x-api-key` header on all inference requests. Set to `false` only for development. |
| `budget_usd` | number \| null | `null` | Gateway-level cumulative spend cap in USD. Blocks all requests once exhausted. Reset via `DELETE /gateways/{id}/budget`. `null` = no cap. |
| `cache_ttl` | integer | `0` | Response cache TTL in seconds. `0` disables the cache. Cached responses are keyed on `SHA-256(provider:model:canonical_body)`. |
| `retry_count` | integer | `2` | Maximum number of retry attempts against the primary provider on 5xx errors before the fallback chain is walked. |
| `timeout_ms` | integer | `60000` | Per-upstream-request timeout in milliseconds. Applies to each attempt individually, not the total request time. |
| `log_payloads` | boolean | `true` | Whether to store request and response bodies in the log table. Disable for sensitive workloads where prompt/response content must not be persisted. |

---

## Rate limiting

| Field | Type | Default | Description |
|---|---|---|---|
| `rate_limit` | object \| null | `null` (disabled) | Gateway-level sliding-window rate limit applied to all callers. Default: `null` (disabled). Example: `{"requests": 100, "window_sec": 60}`. Per-token limits override this for individual tokens. |
| `rate_limit.requests` | integer | — | Maximum requests allowed in the window. |
| `rate_limit.window_sec` | integer | — | Window duration in seconds. |

Example:

```json
"rate_limit": {"requests": 100, "window_sec": 60}
```

---

## IP allowlist

| Field | Type | Default | Description |
|---|---|---|---|
| `ip_allowlist` | array of strings | `[]` | CIDR blocks permitted to call this gateway. An empty array allows all source IPs. Requests from IPs outside the list return `403 FORBIDDEN`. |

Example:

```json
"ip_allowlist": ["10.0.0.0/8", "192.168.1.0/24"]
```

---

## Guardrails

| Field | Type | Default | Description |
|---|---|---|---|
| `guardrails` | array | `[]` | Ordered list of guardrail configs. Evaluated in array order within each tier. First `block` verdict short-circuits the pipeline. |

!!! note "Backwards compatibility"
    The legacy key `detectors` is still accepted and behaves identically to `guardrails`. New configurations should use `guardrails`.

Each guardrail object has a common set of fields plus type-specific fields:

| Field | Type | Description |
|---|---|---|
| `type` | string | Guardrail type: `regex`, `keyword`, `presidio`, `prompt_guard`, `pii_protector`. |
| `name` | string | Human-readable name used in block messages and logs. |
| `action` | string | One of `block`, `scrub`, or `flag`. |
| `target` | string | One of `request`, `response`, or `both`. |

See the [Guardrail Pipeline](../security/guardrails.md) page for full per-type field documentation.

---

## Provider-specific fields

### Azure OpenAI

| Field | Type | Default | Description |
|---|---|---|---|
| `azure_endpoint` | string \| null | `null` | Azure OpenAI resource URL, e.g. `https://myresource.openai.azure.com`. Required for Azure provider. |
| `azure_deployment` | string \| null | `null` | Azure deployment name. Replaces the model name in the request URL path. |
| `azure_api_version` | string | `"2024-02-01"` | Azure OpenAI API version appended as `?api-version=` query param. |

### AWS Bedrock

| Field | Type | Default | Description |
|---|---|---|---|
| `bedrock_region` | string | `"us-east-1"` | AWS region for Bedrock API calls. Used in SigV4 request signing. |

### Google Vertex AI

| Field | Type | Default | Description |
|---|---|---|---|
| `vertex_project` | string \| null | `null` | Google Cloud project ID. Required for Vertex AI. |
| `vertex_region` | string | `"us-central1"` | Google Cloud region for Vertex AI API calls. |

### Provider base URL overrides

| Field | Type | Default | Description |
|---|---|---|---|
| `provider_base_urls` | object | `{}` | Map of `provider_name → base URL`. Overrides the gateway's hardcoded default endpoint for any provider. Useful for Ollama on a remote host, internal proxies, and staging environments. |

Example:

```json
"provider_base_urls": {
  "ollama": "http://192.168.1.50:11434",
  "openai": "https://my-openai-proxy.internal"
}
```

---

## Per-request header overrides

These headers can be sent on individual inference requests to override gateway config for that request only.

| Header | Type | Description |
|---|---|---|
| `x-aig-byok-alias` | string | Use a non-default BYOK provider key alias for this request. Must match an alias stored for the resolved provider. |
| `x-aig-meta-{key}` | string | Attach a custom key-value pair to the request log entry and make it available in routing rule conditions as `meta.{key}`. Multiple headers allowed. |
| `x-aig-collect-log` | `"0"`, `"false"`, or `"1"` | `"0"` or `"false"` = skip writing this request to the log table entirely. `"1"` = log (default). |
| `x-aig-collect-log-payload` | `"0"`, `"false"`, or `"1"` | `"0"` or `"false"` = log request metadata but omit the prompt and response body. `"1"` = log body (default). Does not affect the gateway-level `log_payloads` setting. |
| `x-aig-provider-{field}` | string | Strip the `x-aig-provider-` prefix and forward the header verbatim to the upstream provider. Useful for provider-specific beta flags. |

!!! note
    `x-aig-provider-*` headers are forwarded unconditionally to whatever provider handles the request. Sending a provider-specific header to the wrong provider is harmless but may produce unexpected behaviour if the provider rejects unknown headers.

---

## Applying config changes

```bash
# Enable caching and set a budget
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "cache_ttl": 300,
      "budget_usd": 200.00
    }
  }'

# Disable authentication (development only)
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{"config": {"auth_required": false}}'

# Add an IP allowlist
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{"config": {"ip_allowlist": ["10.0.0.0/8"]}}'
```

---

## See also

- [Tenants & Gateways API](../api-reference/tenants-gateways.md)
- [Authentication](../api-reference/authentication.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Guardrail Pipeline](../security/guardrails.md)
