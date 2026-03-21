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

| Code | HTTP Status | Description |
|---|---|---|
| `UNAUTHORIZED` | 401 | The request did not include a valid auth token, or the token has expired or been revoked. |
| `FORBIDDEN` | 403 | The token is valid but does not have permission. Causes: `viewer` role on inference, or IP not in the gateway's `ip_allowlist`. |
| `TENANT_NOT_FOUND` | 404 | The tenant or gateway slug in the URL does not exist. |
| `INVALID_REQUEST` | 400 | Malformed request body, missing required fields, or an unrecognised parameter value. |
| `RATE_LIMITED` | 429 | The sliding-window rate limit was exceeded. The response includes `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset` headers. |
| `QUOTA_EXCEEDED` | 429 | The configured spend budget has been exhausted (gateway-level or per-token). |
| `DETECTOR_BLOCKED` | 400 | The detector pipeline (regex, keyword, PII, Presidio, or LLM Guard) matched with a `block` action. The `message` field names the blocking detector. |
| `GUARDRAIL_BLOCKED` | 400 | Llama Guard 3 classified the request as unsafe. The `message` includes the harm category (e.g. `unsafe S1`). See note below. |
| `PROVIDER_ERROR` | 502 | The upstream provider returned a 5xx error and all retries were exhausted for that provider. |
| `ALL_PROVIDERS_FAILED` | 502 | All providers in the routing chain (primary + all fallbacks) returned errors or timed out. |
| `INTERNAL` | 500 | An unexpected error occurred inside the gateway. Check the gateway error log for details. |

---

## Notes on specific codes

### GUARDRAIL_BLOCKED — streaming vs. non-streaming

In **non-streaming** mode, a guardrail block returns `HTTP 400` with the `GUARDRAIL_BLOCKED` error JSON.

In **streaming** mode (`"stream": true`), the guardrail check runs before the provider call. When a block occurs the gateway returns `HTTP 200` with a synthetic SSE stream containing an error message chunk followed by `data: [DONE]`. This is necessary because some streaming clients do not gracefully handle a non-200 HTTP status on a streaming response.

```
data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"[Blocked: unsafe S1 — Violent Crimes]"},"finish_reason":"stop"}]}

data: [DONE]
```

!!! note
    Your client should inspect the chunk content for the block message if it processes streaming responses. The log entry for the request will have `blocked: true` and `blocked_by: "guardrail"` regardless of the HTTP status returned.

### RATE_LIMITED — response headers

When `RATE_LIMITED` is returned, the response includes three headers:

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | The configured request limit for the window. |
| `X-RateLimit-Remaining` | Estimated remaining requests in the current window. |
| `X-RateLimit-Reset` | Unix timestamp (seconds) when the window resets. |

### ALL_PROVIDERS_FAILED — when to expect it

This error is returned only when all of the following are true:

1. The primary provider returned 5xx errors on every attempt (up to `retry_count`).
2. Every fallback provider in the routing rule's `fallbacks` array also failed.

4xx responses from a provider are **not** retried and are returned to the caller immediately (the provider's error is forwarded, not wrapped in `ALL_PROVIDERS_FAILED`).

!!! warning
    A `PROVIDER_ERROR` on a single provider with no fallbacks configured behaves identically to `ALL_PROVIDERS_FAILED` — both return `502`. Configure fallbacks in your routing rules to avoid single-provider outages surfacing as errors to your end users.

### INVALID_REQUEST — common causes

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
    "code": "UNAUTHORIZED",
    "message": "Missing or invalid authentication token"
  }
}
```

### 429 — rate limited

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "Rate limit exceeded: 100 requests per 60 seconds"
  }
}
```

### 429 — quota exceeded

```json
{
  "error": {
    "code": "QUOTA_EXCEEDED",
    "message": "Budget limit reached"
  }
}
```

### 400 — detector blocked

```json
{
  "error": {
    "code": "DETECTOR_BLOCKED",
    "message": "Request blocked by detector: pii-scan"
  }
}
```

### 502 — all providers failed

```json
{
  "error": {
    "code": "ALL_PROVIDERS_FAILED",
    "message": "All upstream providers failed after retries and fallbacks"
  }
}
```

---

## See also

- [Authentication](authentication.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Detector Pipeline](../security/detectors.md)
- [Request Pipeline](../concepts/request-pipeline.md)
