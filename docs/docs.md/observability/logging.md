# Request Logging

The request log is your primary tool for understanding what your gateway is doing. Every inference request produces a log entry with the provider used, token counts, cost, latency, cache status, and (optionally) the full prompt and response text. You can view logs in real time in the admin UI under **Logs**, or query them programmatically via the API.

Logging happens after the response is sent — it does not add latency to the request path.

---

## Log entry fields

### Identity

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique request ID (UUID) |
| `tenant_id` | string | Tenant that owns this gateway |
| `gateway_id` | string | Gateway through which the request was routed |
| `user_id` | string \| null | User ID extracted from the auth token |
| `token_label` | string \| null | Human-readable label of the auth token used |

### Routing

| Field | Type | Description |
|---|---|---|
| `provider` | string | Provider that handled the request (e.g. `openai`, `anthropic`) |
| `model` | string | Model name as sent in the request |
| `fallback_provider` | string \| null | Provider used if the primary provider failed |
| `fallback_model` | string \| null | Model used on the fallback attempt |
| `upstream_attempts` | integer | Number of upstream attempts (1 = no retry needed) |

### Status

| Field | Type | Description |
|---|---|---|
| `status` | integer | HTTP status code returned to the caller |
| `blocked` | boolean | Whether the request was blocked by a detector or guardrail |
| `blocked_by` | string \| null | Name of the detector or rule that blocked the request |
| `block_reason` | string \| null | Human-readable block reason |

### Cache

| Field | Type | Description |
|---|---|---|
| `cached` | boolean | Whether the response was served from cache |
| `saved_cost_usd` | number \| null | Cost saved by serving from cache |
| `saved_latency_ms` | integer \| null | Latency saved by serving from cache |

### Tokens

| Field | Type | Description |
|---|---|---|
| `input_tokens` | integer | Prompt tokens consumed |
| `output_tokens` | integer | Completion tokens generated |
| `cache_creation_tokens` | integer \| null | Tokens written to Anthropic prompt cache |
| `cache_read_tokens` | integer \| null | Tokens read from Anthropic prompt cache |

### Cost

| Field | Type | Description |
|---|---|---|
| `cost_usd` | number \| null | Estimated cost in USD, computed from the prices table |

### Timing

| Field | Type | Description |
|---|---|---|
| `latency_ms` | integer | Total request latency from gateway receipt to response sent |
| `upstream_latency_ms` | integer \| null | Time spent waiting for the upstream provider |
| `time_to_first_token_ms` | integer \| null | Time to first SSE token (streaming requests only) |

### Payload

| Field | Type | Description |
|---|---|---|
| `prompt` | string \| null | Full prompt text (null if `log_payloads: false` or suppressed per-request) |
| `response` | string \| null | Full response text (null for streaming requests, or if payload logging is off) |

### Detectors

| Field | Type | Description |
|---|---|---|
| `detector_results` | object \| null | Map of detector name → result for all detectors that ran |

### Custom metadata

| Field | Type | Description |
|---|---|---|
| `meta` | object \| null | Key/value map from `x-aig-meta-*` request headers |

---

## Payload logging control

### Gateway-level (persists across all requests)

Disable payload storage globally for a gateway:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"config": {"log_payloads": false}}'
```

When `log_payloads` is `false`, the `prompt` and `response` fields are `null` for every request through that gateway.

### Per-request headers

| Header | Value | Effect |
|---|---|---|
| `x-aig-collect-log` | `false` | Skip writing a log entry entirely for this request |
| `x-aig-collect-log-payload` | `false` | Write log metadata only; set `prompt` and `response` to null for this request |

```bash
# Skip logging entirely
curl -s -X POST "https://gateway.example.com/v1/myapp/prod/openai/chat/completions" \
  -H "x-aig-collect-log: false" \
  ...

# Log metadata but not the prompt/response text
curl -s -X POST "https://gateway.example.com/v1/myapp/prod/openai/chat/completions" \
  -H "x-aig-collect-log-payload: false" \
  ...
```

!!! warning "Payload suppression is per-request"
    `x-aig-collect-log-payload: false` only suppresses payloads for the single request that includes the header. It does not change the gateway-level `log_payloads` setting.

---

## Attaching custom metadata

Any request header prefixed with `x-aig-meta-` is captured in the `meta` field of the log entry:

```bash
curl -s -X POST "https://gateway.example.com/v1/myapp/prod/openai/chat/completions" \
  -H "x-aig-meta-session-id: sess_abc123" \
  -H "x-aig-meta-feature-flag: new-summariser" \
  ...
```

The log entry will contain:

```json
{
  "meta": {
    "session-id": "sess_abc123",
    "feature-flag": "new-summariser"
  }
}
```

---

## Querying logs

```bash
GET /admin/v1/logs
```

Common query parameters:

| Parameter | Description |
|---|---|
| `limit` | Number of entries to return (default: 50) |
| `offset` | Pagination offset |
| `tenant_id` | Filter by tenant |
| `gateway_id` | Filter by gateway |
| `provider` | Filter by provider name |
| `status` | Filter by HTTP status code |
| `blocked` | `true` / `false` |
| `cached` | `true` / `false` |
| `from` | ISO 8601 start timestamp |
| `to` | ISO 8601 end timestamp |

```bash
# Last 10 blocked requests
curl "https://gateway.example.com/admin/v1/logs?blocked=true&limit=10" \
  -H "x-aig-token: <admin-token>"

# Requests for a specific gateway in the last hour
curl "https://gateway.example.com/admin/v1/logs?gateway_id={id}&from=2025-01-01T12:00:00Z" \
  -H "x-aig-token: <admin-token>"
```

---

## Storage

Request logs are stored and retained by the Myra Security platform. Log retention and backend configuration are managed as part of your service agreement. For enterprise retention or export requirements, contact your Myra Security account team.

---

## See also

- [Admin Dashboard](dashboard.md)
- [Gateway Configuration](../configuration/gateway-config.md) — `log_payloads`
