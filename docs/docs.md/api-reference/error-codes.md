# Error Codes

All errors returned by the gateway (admin API and inference endpoints) follow a consistent JSON structure.

---

## Error response format

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable detail about what went wrong"
  }
}
```

The `code` field is a stable machine-readable string. The `message` is informational and may change between releases. Always branch logic on `code`, not `message`.

---

## Error codes

!!! note "Admin API vs inference API error format"
    Inference endpoint errors (`/v1/...`) use the structured format below with `code` and `message` fields. Admin API errors (`/admin/v1/...`) use a simpler flat format: `{"error": "message string"}`.

| Code | HTTP Status | Description |
|---|---|---|
| `unauthorized` | 401 | The request did not include a valid auth token, or the token has expired or been revoked. |
| `forbidden` | 403 | The token is valid but does not have permission. Causes: `viewer` role on inference, or IP not in the gateway's `ip_allowlist`. |
| `tenant_not_found` | 404 | The tenant or gateway slug in the URL does not exist. |
| `invalid_request` | 400 | Malformed request body, missing required fields, or an unrecognised parameter value. |
| `rate_limited` | 429 | The sliding-window rate limit was exceeded. The response includes `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `Retry-After` headers. |
| `quota_exceeded` | 429 | The configured spend budget has been exhausted (token-level, tenant-level, or gateway-level). |
| `guardrail_blocked` | 400 | A guardrail (regex, keyword, NLP PII Detector, Prompt Guard, PII Protector) matched with a `block` action. The `message` names the blocking guardrail and pattern/category. |
| `provider_error` | 502 | The upstream provider returned a 5xx error and all retries were exhausted for that provider. |
| `all_providers_failed` | 502 | All providers in the routing chain (primary + all fallbacks) returned errors or timed out. |
| `internal_error` | 500 | An unexpected error occurred inside the gateway. Check the gateway error log for details. |

---

## Notes on specific codes

### guardrail_blocked — streaming vs. non-streaming

In **non-streaming** mode, a guardrail block returns `HTTP 400` with the `guardrail_blocked` error JSON.

In **streaming** mode (`"stream": true`), the guardrail check runs before the provider call. When a block occurs the gateway returns `HTTP 200` with a synthetic SSE stream containing an error message chunk followed by `data: [DONE]`. This is necessary because some streaming clients do not gracefully handle a non-200 HTTP status on a streaming response.

```
data: {"id":"...","choices":[{"delta":{"content":"[Blocked: S1]"},"finish_reason":"stop"}]}

data: [DONE]
```

!!! note
    Your client should inspect the chunk content for the block message if it processes streaming responses. The log entry for the request will have `blocked: true` and `blocked_by: "guardrail"` regardless of the HTTP status returned.

!!! note "Retry-After semantics"
    The `Retry-After` header contains the window duration in seconds (e.g. `60`), not an absolute timestamp. It represents the maximum time before the window resets — retrying after `Retry-After` seconds is guaranteed to succeed if no new requests have been made.

### rate_limited — response headers

When `rate_limited` is returned, the response includes three headers:

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | The configured request limit for the window. |
| `X-RateLimit-Remaining` | Estimated remaining requests in the current window (0 when blocked). |
| `Retry-After` | The window duration in seconds — the minimum time before retrying. |

### all_providers_failed — when to expect it

This error is returned only when all of the following are true:

1. The primary provider returned 5xx errors on every attempt (up to `retry_count`).
2. Every fallback provider in the routing rule's `fallbacks` array also failed.

4xx responses from a provider are **not** retried and are returned to the caller immediately (the provider's error is forwarded, not wrapped in `ALL_PROVIDERS_FAILED`).

!!! warning
    A `PROVIDER_ERROR` on a single provider with no fallbacks configured behaves identically to `ALL_PROVIDERS_FAILED` — both return `502`. Configure fallbacks in your routing rules to avoid single-provider outages surfacing as errors to your end users.

### invalid_request — common causes

- Missing required fields in a POST body (e.g. no `slug` when creating a tenant)
- Unknown `bucket` value in `GET /stats/timeseries`
- `n` outside the range 1–168
- Malformed JSON body

---

## Example error responses

### 401 — missing token

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Missing or invalid gateway token"
  }
}
```

### 429 — rate limited

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Rate limit: 101/100 requests per 60s"
  }
}
```

### 429 — quota exceeded

```json
{
  "error": {
    "code": "quota_exceeded",
    "message": "Gateway budget $200.0000 exceeded (spent $200.0019).\n
      Adjust budget_usd in the gateway config (PATCH /admin/v1/gateways/{id})\n
      or reset spend (DELETE /admin/v1/gateways/{id}/budget)."
  }
}
```

### 400 — guardrail blocked

```json
{
  "error": {
    "code": "guardrail_blocked",
    "message": "Request blocked by content policy (block-pci): cc – Credit/Debit Card Number"
  }
}
```

**502 — all providers failed** — returned when every provider in the fallback chain has been exhausted. The JSON envelope is identical to the above; only `code` and `message` differ.

---

## See also

- [Authentication](authentication.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Guardrail Pipeline](../security/guardrails.md)
- [Request Pipeline](../concepts/request-pipeline.md)
