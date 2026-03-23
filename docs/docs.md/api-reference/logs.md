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
| `model` | string | — | Filter by model name (e.g. `gpt-4o`). |
| `status` | integer | — | Filter by HTTP status code returned to the client (e.g. `200`, `429`). |
| `blocked` | integer | — | `1` to return only blocked requests. Omit to return all. |
| `guardrail_outcome` | string | — | Filter by guardrail result. One of: `blocked`, `scrubbed`, `flagged`, `any`. `any` matches requests where any guardrail fired. |
| `since` | integer | — | Return only entries at or after this time, as Unix milliseconds. |
| `limit` | integer | `50` | Maximum number of entries to return. Maximum: `200`. |
| `offset` | integer | `0` | Skip this many entries (for pagination). |

!!! note
    All filters are optional and can be combined. The result is always ordered newest-first.

---

## LogEntry fields

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique log entry ID. |
| `ts` | string | Request timestamp in ISO 8601 format (e.g. `"2025-03-21T10:00:00Z"`). |
| `tenant_id` | string | Tenant UUID. |
| `gateway_id` | string | Gateway UUID. |
| `provider` | string | Provider that handled the request (after routing). |
| `model` | string | Model sent to the provider (after routing/rewrite). |
| `status` | integer | HTTP status code returned to the client. |
| `cached` | integer | `1` if the response was served from cache, `0` otherwise. |
| `blocked` | integer | `1` if the request was blocked before reaching the provider, `0` otherwise. |
| `blocked_by` | string \| null | Which middleware blocked the request (`rate_limit`, `ip_allowlist`, `guardrail`, `quota`). |
| `block_reason` | string \| null | Human-readable block reason. |
| `guardrail_verdict` | string \| null | Guardrail verdict string if a Prompt Guard guardrail fired (e.g. `unsafe S1`). |
| `detectors_fired` | array | Names of all guardrails that produced a non-pass verdict (blocked, scrubbed, or flagged). Empty array when no guardrail fired. |
| `scrub_applied` | integer | `1` if a `scrub` action was applied by any guardrail, `0` otherwise. |
| `input_tokens` | integer | Prompt tokens consumed. |
| `output_tokens` | integer | Completion tokens generated. |
| `cost_usd` | number | Estimated cost in USD for this request. |
| `latency_ms` | integer | End-to-end request latency in milliseconds. |
| `upstream_latency_ms` | integer | Time waiting for the provider only. |
| `guardrail_latency_ms` | integer \| null | Time spent in Tier 2 guardrail sidecar calls, if any. |
| `upstream_attempts` | integer | Number of upstream attempts (1 = no retries, >1 = retries occurred). |
| `fallback_provider` | string \| null | Provider used after the primary failed, if any. |
| `fallback_model` | string \| null | Model used on the fallback provider, if any. |
| `saved_cost_usd` | number | For cached requests: the cost that would have been incurred without the cache. |
| `request_size_bytes` | integer | Size of the request body in bytes. |
| `trace_id` | string \| null | Links this log entry to a detailed execution trace. `null` when gateway tracing is disabled. See [Traces API](traces.md). |
| `response_raw` | string \| null | Raw LLM response body before PII token restoration. Only present when `pii_protector` is active and `log_payloads: true`. |

The following fields are only returned by `GET /logs/{id}` (single-entry endpoint), not by the list endpoint:

| Field | Type | Description |
|---|---|---|
| `prompt` | string \| null | Request body sent to the provider. `null` when `log_payloads: false`. |
| `response` | string \| null | Provider response body. `null` when `log_payloads: false`. |
| `prompt_scrubbed` | string \| null | Request messages after PII tokenization (tokens visible, original values absent). Only present when `pii_protector` detects PII. |

!!! note
    Request and response body content is only stored when `log_payloads: true` is set in the gateway config (the default). When disabled, all fields above are still logged but the prompt/response text is omitted. Individual requests can suppress payload logging with the `x-aig-collect-log-payload: false` header.

---

## GET /logs/{id}

Returns a single log entry by its ID.

```bash
curl "https://<your-gateway-host>/admin/v1/logs/log_abc789"
```

Returns the same [LogEntry](#logentry-fields) object as in the list endpoint. Returns `404` if not found.

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

### Fetch only blocked requests for a tenant

```bash
curl "https://<your-gateway-host>/admin/v1/logs?tenant_id=ten_abc123&blocked=1&limit=50"
```

### Fetch requests where a guardrail fired (blocked, scrubbed, or flagged)

```bash
curl "https://<your-gateway-host>/admin/v1/logs?gateway_id=gw_xyz789&guardrail_outcome=any&limit=50"
```

### Fetch only guardrail-blocked requests

```bash
curl "https://<your-gateway-host>/admin/v1/logs?gateway_id=gw_xyz789&guardrail_outcome=blocked&limit=50"
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
  "ts": "2025-03-21T10:00:32Z",
  "tenant_id": "ten_abc123",
  "gateway_id": "gw_xyz789",
  "provider": "openai",
  "model": "gpt-4o",
  "status": 200,
  "cached": 0,
  "blocked": 0,
  "blocked_by": null,
  "block_reason": null,
  "guardrail_verdict": null,
  "detectors_fired": [],
  "scrub_applied": 0,
  "input_tokens": 512,
  "output_tokens": 128,
  "cost_usd": 0.00448,
  "latency_ms": 842,
  "upstream_latency_ms": 780,
  "guardrail_latency_ms": null,
  "upstream_attempts": 1,
  "fallback_provider": null,
  "fallback_model": null,
  "saved_cost_usd": 0,
  "request_size_bytes": 1024,
  "trace_id": null,
  "response_raw": null
}
```

---

## See also

- [Stats API](stats.md)
- [Traces API](traces.md)
- [Gateway Configuration Reference](../reference/config-reference.md)
- [Error Codes](error-codes.md)
- [Request Pipeline](../concepts/request-pipeline.md)
