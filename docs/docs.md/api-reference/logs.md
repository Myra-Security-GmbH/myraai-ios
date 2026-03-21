# Logs API

The Logs API provides access to the structured request log written by the gateway's log phase. Each entry records full identity, routing, security, token usage, cost, and timing for one inference request.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## GET /logs

Returns an array of log entries in reverse-chronological order (newest first).

```bash
curl "https://<your-gateway-host>/admin/v1/logs"
```

### Query parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `tenant_id` | string | — | Filter by tenant UUID. |
| `gateway_id` | string | — | Filter by gateway UUID. |
| `provider` | string | — | Filter by provider name (e.g. `openai`, `anthropic`). |
| `since` | string | — | Return only entries at or after this time. Accepts ISO 8601 datetime (`2026-03-01T00:00:00Z`) or Unix milliseconds. |
| `limit` | integer | `100` | Maximum number of entries to return. |
| `offset` | integer | `0` | Skip this many entries (for pagination). |

!!! note
    All filters are optional and can be combined. The result is always ordered newest-first.

---

## LogEntry fields

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique log entry ID. |
| `ts` | integer | Request timestamp as Unix milliseconds. |
| `tenant` | string | Tenant slug. |
| `tenant_id` | string | Tenant UUID. |
| `gateway_id` | string | Gateway UUID. |
| `provider` | string | Provider that handled the request (after routing). |
| `model` | string | Model sent to the provider (after routing/rewrite). |
| `status` | integer | HTTP status code returned to the client. |
| `cached` | boolean | `true` if the response was served from cache. |
| `blocked` | boolean | `true` if the request was blocked before reaching the provider. |
| `blocked_by` | string \| null | Which middleware blocked the request (`auth`, `rate_limit`, `ip_allowlist`, `detector`, `guardrail`, `quota`). |
| `block_reason` | string \| null | Human-readable block reason. |
| `guardrail_verdict` | string \| null | Llama Guard verdict string if guardrails fired (e.g. `unsafe S1`). |
| `input_tokens` | integer | Prompt tokens consumed. |
| `output_tokens` | integer | Completion tokens generated. |
| `cost_usd` | number | Estimated cost in USD for this request. |
| `latency_ms` | integer | End-to-end request latency in milliseconds (gateway receives request → sends last byte of response). |
| `upstream_latency_ms` | integer | Time waiting for the provider only. |
| `guardrail_latency_ms` | integer | Time spent in the Llama Guard service call, if any. |
| `upstream_attempts` | integer | Number of upstream attempts (1 = no retries, >1 = retries occurred). |
| `fallback_provider` | string \| null | Provider used after the primary failed, if any. |
| `fallback_model` | string \| null | Model used on the fallback provider, if any. |
| `saved_cost_usd` | number | For cached requests: the cost that would have been incurred without the cache. |
| `request_size_bytes` | integer | Size of the request body in bytes. |

!!! note
    Request and response body content is only stored when `log_payloads: true` is set in the gateway config (the default). When disabled, all fields above are still logged but the prompt/response text is omitted. Individual requests can suppress payload logging with the `x-aig-collect-log-payload: false` header.

---

## Examples

### Fetch the last 100 requests

```bash
curl "https://<your-gateway-host>/admin/v1/logs?limit=100"
```

### Fetch logs for a specific gateway

```bash
curl "https://<your-gateway-host>/admin/v1/logs?gateway_id=gw_xyz789&limit=50"
```

### Fetch blocked requests for a tenant

```bash
# All logs for a tenant — filter for blocked=true in your application,
# or query with a small limit and paginate
curl "https://<your-gateway-host>/admin/v1/logs?tenant_id=ten_abc123&limit=100"
```

### Fetch logs since a specific ISO 8601 time

```bash
curl "https://<your-gateway-host>/admin/v1/logs?since=2026-03-21T00:00:00Z&limit=200"
```

### Fetch logs since a Unix timestamp (milliseconds)

```bash
curl "https://<your-gateway-host>/admin/v1/logs?since=1742544000000&limit=200"
```

### Fetch the last hour of OpenAI requests

```bash
SINCE=$(date -d "1 hour ago" +%s)000   # convert seconds to ms
curl "https://<your-gateway-host>/admin/v1/logs?provider=openai&since=${SINCE}&limit=500"
```

### Paginate through a large result set

```bash
# Page 1
curl "https://<your-gateway-host>/admin/v1/logs?gateway_id=gw_xyz789&limit=100&offset=0"

# Page 2
curl "https://<your-gateway-host>/admin/v1/logs?gateway_id=gw_xyz789&limit=100&offset=100"
```

### Example log entry

```json
{
  "id": "log_abc789",
  "ts": 1742547632000,
  "tenant": "myapp",
  "tenant_id": "ten_abc123",
  "gateway_id": "gw_xyz789",
  "provider": "openai",
  "model": "gpt-4o",
  "status": 200,
  "cached": false,
  "blocked": false,
  "blocked_by": null,
  "block_reason": null,
  "guardrail_verdict": null,
  "input_tokens": 512,
  "output_tokens": 128,
  "cost_usd": 0.00448,
  "latency_ms": 842,
  "upstream_latency_ms": 780,
  "guardrail_latency_ms": 0,
  "upstream_attempts": 1,
  "fallback_provider": null,
  "fallback_model": null,
  "saved_cost_usd": 0,
  "request_size_bytes": 1024
}
```

---

## See also

- [Stats API](stats.md)
- [Gateway Configuration Reference](../reference/config-reference.md)
- [Error Codes](error-codes.md)
- [Request Pipeline](../concepts/request-pipeline.md)
