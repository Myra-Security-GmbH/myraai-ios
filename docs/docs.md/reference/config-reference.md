# Gateway configuration reference

Every gateway has a `config` JSON object that controls authentication, caching, timeouts, security, routing, and provider settings. Update it with `PATCH /admin/v1/gateways/{id}`.

The config is **merged at the top level** on each PATCH — only the fields you include are changed. Nested objects (`rate_limit`) are replaced in full when provided.

---

## Full default config

```json
{
  "auth_required": true,
  "budget_usd": null,
  "budget_period": "monthly",
  "tenant_budget_usd": null,
  "tenant_budget_period": "monthly",
  "cache_ttl": 0,
  "retry_count": 2,
  "timeout_ms": 60000,
  "log_payloads": true,
  "rate_limit": null,
  "ip_allowlist": [],
  "guardrails": [],
  "circuit_breaker": null,
  "webhooks": null,
  "siem": null,
  "azure_endpoint": null,
  "azure_deployment": null,
  "azure_api_version": "2024-02-01",
  "bedrock_region": "us-east-1",
  "vertex_project": null,
  "vertex_region": "us-central1",
  "provider_base_urls": {},
  "tracing": null,
  "web_search": null
}
```

---

## Core fields

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `auth_required` | boolean | `true` | Require a valid `x-aig-token`, `Authorization: Bearer`, or `x-api-key` header on all inference requests. Set to `false` only for development. |
| `budget_usd` | number \| null | `null` | Gateway-level spend cap in USD for the current budget period. Blocks all requests once exhausted. `null` = no cap. |
| `budget_period` | string | `"monthly"` | Period over which gateway spend is accumulated. One of: `"daily"` (resets each UTC day), `"monthly"` (resets each calendar month), `"total"` (lifetime, never resets). |
| `tenant_budget_usd` | number \| null | `null` | Tenant-level spend cap in USD. Applies across all gateways belonging to the tenant. `null` = no cap. |
| `tenant_budget_period` | string | `"monthly"` | Period for the tenant-level budget. One of: `"daily"`, `"monthly"`, `"total"`. |
| `cache_ttl` | integer | `0` | Response cache TTL in seconds. `0` disables the cache. Cached responses are keyed on `SHA-256(provider:model:canonical_body)`. |
| `retry_count` | integer | `2` | Maximum number of retry attempts against the primary provider on 5xx errors before the fallback chain is walked. |
| `timeout_ms` | integer | `60000` | Per-upstream-request timeout in milliseconds. Applies to each attempt individually, not the total request time. |
| `log_payloads` | boolean | `true` | Store request and response bodies in the log table. Disable for sensitive workloads where prompt/response content must not be persisted. |

---

## Rate limiting

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `rate_limit` | object \| null | `null` (disabled) | Gateway-level sliding-window rate limit applied to all callers. Default: `null` (disabled). Example: `{"requests": 100, "window_sec": 60}`. Per-token limits are checked independently — a request can be blocked by either limit. |
| `rate_limit.requests` | integer | — | Maximum requests allowed in the window. |
| `rate_limit.window_sec` | integer | — | Window duration in seconds. |

> ⭐ **Example:**

```json
"rate_limit": {"requests": 100, "window_sec": 60}
```

---

## IP allowlist

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `ip_allowlist` | array of strings | `[]` | CIDR blocks permitted to call this gateway. An empty array allows all source IPs. Requests from IPs outside the list return `403 FORBIDDEN`. |

> ⭐ **Example:**

```json
"ip_allowlist": ["10.0.0.0/8", "192.168.1.0/24"]
```

---

## Guardrails

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `guardrails` | array | `[]` | Ordered list of guardrail configs. Evaluated in array order within each tier. First `block` verdict short-circuits the pipeline. |

> 💡 **Note:** The legacy key `detectors` is still accepted and behaves identically to `guardrails`. New configurations should use `guardrails`.

Each guardrail object has a common set of fields plus type-specific fields:

| **Field** | **Type** | **Description** |
|---|---|---|
| `type` | string | Guardrail type: `regex`, `keyword`, `jailbreak`, `json_schema`, `contains_code`, `gibberish`, `language`, `presidio`, `prompt_guard`, `pii_protector`. |
| `name` | string | Human-readable name used in block messages and logs. |
| `action` | string | One of `block`, `scrub`, or `flag`. |
| `target` | string | One of `request`, `response`, or `both`. |

See the [Guardrail Pipeline](../security/guardrails.md) page for full per-type field documentation.

---

## Provider-specific fields

### Azure OpenAI

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `azure_endpoint` | string \| null | `null` | Azure OpenAI resource URL, e.g. `https://myresource.openai.azure.com`. Required for Azure provider. |
| `azure_deployment` | string \| null | `null` | Azure deployment name. Replaces the model name in the request URL path. |
| `azure_api_version` | string | `"2024-02-01"` | Azure OpenAI API version appended as `?api-version=` query param. |

### AWS Bedrock

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `bedrock_region` | string | `"us-east-1"` | AWS region for Bedrock API calls. Used in SigV4 request signing. |

### Google Vertex AI

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `vertex_project` | string \| null | `null` | Google Cloud project ID. Required for Vertex AI. |
| `vertex_region` | string | `"us-central1"` | Google Cloud region for Vertex AI API calls. |

### Provider base URL overrides

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `provider_base_urls` | object | `{}` | Map of `provider_name → base URL`. Overrides the hardcoded default endpoint of the gateway for any provider. Useful for Ollama on a remote host, internal proxies, and staging environments. |

> ⭐ **Example:**

```json
"provider_base_urls": {
  "ollama": "http://192.168.1.50:11434",
  "openai": "https://my-openai-proxy.internal"
}
```

---

## Circuit breaker

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `circuit_breaker` | object \| null | `null` | Set to enable the per-provider circuit breaker. `null` disables it entirely. |
| `circuit_breaker.enabled` | boolean | `false` | Must be `true` to activate the breaker. |
| `circuit_breaker.failure_threshold` | integer | `5` | Number of failures within `window_sec` before the breaker opens. |
| `circuit_breaker.window_sec` | integer | `60` | Sliding window in seconds over which failures are counted. |
| `circuit_breaker.cooldown_ms` | integer | `30000` | Milliseconds to wait in the Open state before allowing a probe request. |
| `circuit_breaker.failure_status_codes` | array | `[500,502,503,504]` | HTTP status codes that count as failures. Connection and timeout errors always count. |

See [Circuit Breaker](../routing/circuit-breaker.md) for state machine details and examples.

---

## Webhooks

Webhooks deliver structured event payloads to an external HTTP endpoint for integration with alerting, ITSM, and automation systems.

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `webhooks` | object \| null | `null` | Set to enable outgoing webhooks. `null` disables them. |
| `webhooks.url` | string | — | HTTPS endpoint that receives POST requests for each event. |
| `webhooks.secret` | string | — | Optional shared secret included as `X-Webhook-Secret` on every delivery. Use to verify origin in your receiver. |
| `webhooks.events` | array | `["blocked","budget_exceeded","circuit_open"]` | Event types to deliver. Supported values: `blocked`, `budget_exceeded`, `circuit_open`. |

> ⭐ **Example:**

```json
"webhooks": {
  "url": "https://hooks.slack.com/services/...",
  "secret": "mysecret",
  "events": ["blocked", "budget_exceeded"]
}
```

---

## SIEM (gateway-level override)

A gateway-level `siem` key overrides the tenant-level SIEM (Security Information and Event Management) config for that specific gateway. All fields are identical to the tenant-level config.

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `siem` | object \| null | `null` | SIEM backend config for this gateway. Overrides the tenant default. Set `null` to remove the override and fall back to the tenant config. |
| `siem.type` | string | — | Backend: `splunk_hec`, `elasticsearch`, `vector`, `syslog`. |
| `siem.events` | array | `["blocked"]` | Event filter. Values: `blocked`, `guardrail`, `scrubbed`, `all`. |

See [SIEM Integration](../configuration/siem.md) for the full field reference and per-backend examples.

---

## Tracing

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `tracing` | object \| null | `null` | Set to enable request tracing. `null` disables tracing entirely. |
| `tracing.enabled` | boolean | `false` | Activate internal pipeline tracing (Traces API + Playground traces). |
| `tracing.include_bodies` | boolean | `false` | Store the full request message array in the `request_received` trace step. Enable only for debugging. |
| `tracing.otlp_endpoint` | string | — | Base URL of an OpenTelemetry collector (e.g. `http://otel-collector:4318`). Setting this enables OTLP span export. |
| `tracing.service_name` | string | `"ai-gateway"` | `service.name` resource attribute on all emitted OTLP spans. |
| `tracing.headers` | object | `{}` | Extra HTTP headers to include in the OTLP request (e.g. auth tokens for managed collectors). |
| `tracing.sample_rate` | number | `1.0` | Fraction of requests to export via OTLP (0.0 = never, 1.0 = always). |

See [Request Tracing](../observability/tracing.md) for the full pipeline step reference and OTLP integration guide.

---

## Web search

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `web_search` | object \| null | `null` | Set to enable web-search augmentation. `null` disables the feature. |
| `web_search.enabled` | boolean | `false` | Activate web search on this gateway. |
| `web_search.api_key` | string | — | Brave Search API key. Required for all providers except Google Gemini. |
| `web_search.max_results` | integer | `5` | Maximum number of search results to retrieve per query. |
| `web_search.mode` | string | `"opt-in"` | `"opt-in"` — only triggered when the client sends `X-Web-Search: 1`. `"always"` — attempted on every request. |

See [Web Search](../features/web-search.md) for provider support details and usage examples.

---

## Per-request header overrides

These headers can be sent on individual inference requests to override gateway config for that request only.

| **Header** | **Type** | **Description** |
|---|---|---|
| `x-aig-byok-alias` | string | Use a non-default BYOK provider key alias for this request. Must match an alias stored for the resolved provider. |
| `x-aig-meta-{key}` | string | Attach a custom key-value pair to the request log entry and make it available in routing rule conditions as `meta:{key}` (colon notation). Multiple headers allowed. |
| `x-aig-collect-log` | `"0"`, `"false"`, or `"1"` | `"0"` or `"false"` = skip writing this request to the log table entirely. `"1"` = log (default). |
| `x-aig-collect-log-payload` | `"0"`, `"false"`, or `"1"` | `"0"` or `"false"` = log request metadata but omit the prompt and response body. `"1"` = log body (default). Does not affect the gateway-level `log_payloads` setting. |
| `x-aig-provider-{field}` | string | Strip the `x-aig-provider-` prefix and forward the header verbatim to the upstream provider. Useful for provider-specific beta flags. |

> 💡 **Note:** `x-aig-provider-*` headers are forwarded unconditionally to whatever provider handles the request. Sending a provider-specific header to the wrong provider is harmless but may produce unexpected behaviour if the provider rejects unknown headers.

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
