# Stats API

The Stats API exposes aggregated request metrics. Use `GET /stats` for the dashboard summary view (today, yesterday, last 7 days, last hour, last minute) and `GET /stats/timeseries` for time-bucketed data suitable for charts.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## GET /stats

Returns a snapshot of request counts, token usage, cost, and latency across several time windows. Also includes a per-tenant breakdown and the most recent log entries.

```bash
curl https://<your-gateway-host>/admin/v1/stats
```

### Response structure

```json
{
  "today":     { ...PeriodStats },
  "yesterday": { ...PeriodStats },
  "last_7d":   { ...PeriodStats },
  "hour":      { ...PeriodStats },
  "last_min":  { ...PeriodStats },
  "by_tenant": [ ...TenantStats ],
  "recent":    [ ...LogEntry ],
  "recent_blocked": [ ...LogEntry ]
}
```

### PeriodStats fields

| Field | Type | Description |
|---|---|---|
| `requests` | integer | Total inference requests in the period. |
| `cached` | integer | Requests served from cache (no provider call made). |
| `blocked` | integer | Requests blocked by auth, rate limit, quota, or detectors. |
| `scrubbed` | integer | Requests where a guardrail scrubbed PII from the payload but allowed the request through. |
| `flagged` | integer | Requests where a guardrail raised a flag but took no blocking or scrubbing action. |
| `input_tokens` | integer | Total prompt tokens consumed. |
| `output_tokens` | integer | Total completion tokens generated. |
| `cost_usd` | number | Total cost in USD (from model pricing table). |
| `saved_cost_usd` | number | Cost saved by cache hits (would-have-been cost of cached requests). |
| `avg_latency_ms` | number | Average end-to-end request latency in milliseconds. |
| `avg_upstream_latency_ms` | number | Average time waiting for the upstream provider, excluding gateway overhead. |

### TenantStats fields (GET /stats)

`by_tenant` in `GET /stats` is a summary view with the following fields:

| Field | Type | Description |
|---|---|---|
| `tenant_id` | string | Tenant UUID. |
| `tenant` | string | Tenant slug. |
| `requests` | integer | Total requests. |
| `input_tokens` | integer | Total input tokens. |
| `output_tokens` | integer | Total output tokens. |
| `cost_usd` | number | Total cost in USD. |

The full `TenantStats` shape (with `blocked`, `cached`, `errors`, `avg_latency_ms`, etc.) is returned by `GET /stats/analytics`. See below.

### Example response

```json
{
  "today": {
    "requests": 1423,
    "cached": 82,
    "blocked": 14,
    "input_tokens": 1840200,
    "output_tokens": 312400,
    "cost_usd": 9.84,
    "saved_cost_usd": 0.41,
    "avg_latency_ms": 820,
    "avg_upstream_latency_ms": 760
  },
  "yesterday": {
    "requests": 2101,
    "cached": 134,
    "blocked": 22,
    "input_tokens": 2750000,
    "output_tokens": 480000,
    "cost_usd": 14.30,
    "saved_cost_usd": 0.67,
    "avg_latency_ms": 905,
    "avg_upstream_latency_ms": 850
  },
  "last_7d": { "requests": 11200, "cost_usd": 68.12, "..." : "..." },
  "hour":    { "requests": 61, "cost_usd": 0.38, "...": "..." },
  "last_min": { "requests": 2, "cost_usd": 0.01, "...": "..." },
  "by_tenant": [
    {
      "tenant_id": "ten_abc123",
      "tenant": "myapp",
      "requests": 1423,
      "input_tokens": 1840200,
      "output_tokens": 312400,
      "cost_usd": 9.84
    }
  ],

  "recent": [ { "...": "LogEntry" } ],
  "recent_blocked": [ { "...": "LogEntry" } ]
}
```

For LogEntry field definitions see the [Logs API](logs.md).

---

## GET /stats/analytics

Returns latency percentiles, top-model breakdown, and per-tenant, per-gateway, and per-user cost summaries. Used by the analytics dashboard view.

```bash
curl "https://<your-gateway-host>/admin/v1/stats/analytics?since=1742544000000"
```

### Query parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `since` | integer | 24 hours ago | Start of the analysis window as Unix milliseconds. |

### Response structure

```json
{
  "percentiles": { ...LatencyPercentiles },
  "top_models":  [ ...TopModelRow ],
  "by_tenant":   [ ...TenantStats ],
  "by_gateway":  [ ...GatewayStats ],
  "by_user":     [ ...UserStats ]
}
```

### LatencyPercentiles fields

| Field | Type | Description |
|---|---|---|
| `p50` | number \| null | Median end-to-end latency in milliseconds. `null` if no data. |
| `p95` | number \| null | 95th-percentile latency in milliseconds. |
| `p99` | number \| null | 99th-percentile latency in milliseconds. |

Percentiles cover only non-blocked requests.

### TopModelRow fields

| Field | Type | Description |
|---|---|---|
| `model` | string | Model name. |
| `provider` | string | Provider slug (e.g. `openai`, `anthropic`). |
| `requests` | integer | Request count in the window. |
| `cost_usd` | number | Total cost in USD. |
| `avg_latency_ms` | number | Average end-to-end latency in milliseconds. |

Up to 10 models are returned, ordered by request count descending.

### GatewayStats fields

| Field | Type | Description |
|---|---|---|
| `gateway_id` | string | Gateway UUID. |
| `gateway` | string | Gateway slug. |
| `tenant` | string \| null | Tenant slug. |
| `requests` | integer | Total requests. |
| `blocked` | integer | Blocked request count. |
| `cached` | integer | Cache hit count. |
| `input_tokens` | integer | Total input tokens. |
| `output_tokens` | integer | Total output tokens. |
| `cost_usd` | number | Total cost in USD. |
| `saved_cost_usd` | number | Cost saved by cache hits. |
| `avg_latency_ms` | number | Average end-to-end latency in milliseconds. |
| `errors` | integer | Requests that received an HTTP 4xx or 5xx response from the upstream provider. |

### UserStats fields

| Field | Type | Description |
|---|---|---|
| `user_id` | string | User UUID (from the auth token's `user_id` field). |
| `requests` | integer | Total requests attributed to this user. |
| `blocked` | integer | Blocked request count. |
| `cached` | integer | Cache hit count. |
| `input_tokens` | integer | Total input tokens. |
| `output_tokens` | integer | Total output tokens. |
| `cost_usd` | number | Total cost in USD. |
| `saved_cost_usd` | number | Cost saved by cache hits. |
| `avg_latency_ms` | number | Average end-to-end latency in milliseconds. |
| `errors` | integer | Requests that received an HTTP 4xx or 5xx from the upstream provider. |

`by_user` only includes requests made with auth tokens that have a `user_id` set. Anonymous token requests are not included. Up to 50 users are returned, ordered by cost descending.

### Example response

```json
{
  "percentiles": { "p50": 420, "p95": 1840, "p99": 3210 },
  "top_models": [
    { "model": "gpt-4o", "provider": "openai", "requests": 842, "cost_usd": 3.14, "avg_latency_ms": 680 }
  ],
  "by_tenant": [
    {
      "tenant_id": "ten_abc123", "tenant": "myapp",
      "requests": 1423, "blocked": 14, "cached": 82,
      "input_tokens": 1840200, "output_tokens": 312400,
      "cost_usd": 9.84, "saved_cost_usd": 0.41,
      "avg_latency_ms": 820, "errors": 3
    }
  ],
  "by_gateway": [
    {
      "gateway_id": "gw_xyz789", "gateway": "prod", "tenant": "myapp",
      "requests": 1423, "blocked": 14, "cached": 82,
      "input_tokens": 1840200, "output_tokens": 312400,
      "cost_usd": 9.84, "saved_cost_usd": 0.41,
      "avg_latency_ms": 820, "errors": 3
    }
  ],
  "by_user": [
    {
      "user_id": "usr_alice",
      "requests": 341, "blocked": 2, "cached": 18,
      "input_tokens": 440200, "output_tokens": 74800,
      "cost_usd": 2.31, "saved_cost_usd": 0.09,
      "avg_latency_ms": 790, "errors": 1
    }
  ]
}
```

---

## GET /stats/timeseries

Returns an array of time-bucketed data points, suitable for rendering sparklines or charts. Buckets with no activity are included as zero-filled entries so the array length is always exactly `n`.

```bash
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=1h&n=24"
```

### Query parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `bucket` | string | `1h` | Bucket size. One of: `5m`, `15m`, `30m`, `1h`, `6h`, `1d`. |
| `n` | integer | `24` | Number of buckets to return. Range: 1–168. |
| `until` | integer | now | End of the time range as a Unix timestamp in seconds. Defaults to the current time. |

### TimeseriesPoint fields

| Field | Type | Description |
|---|---|---|
| `ts` | integer | Bucket start time as Unix milliseconds. |
| `requests` | integer | Total requests in the bucket. |
| `blocked` | integer | Requests blocked in the bucket. |
| `cost_usd` | number | Total cost in USD for the bucket. |

!!! note
    `ts` is in **Unix milliseconds** (not seconds) for direct compatibility with charting libraries that expect millisecond-precision timestamps (e.g. Chart.js, Recharts, Grafana).

### Example response

```json
[
  {"ts": 1742540400000, "requests": 42, "blocked": 1, "cost_usd": 0.0314},
  {"ts": 1742544000000, "requests": 67, "blocked": 0, "cost_usd": 0.0521},
  {"ts": 1742547600000, "requests": 0,  "blocked": 0, "cost_usd": 0.0},
  {"ts": 1742551200000, "requests": 18, "blocked": 2, "cost_usd": 0.0119}
]
```

---

## Example curl requests

### Today's requests by hour (last 24 hours)

```bash
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=1h&n=24"
```

### Yesterday's requests by hour

```bash
# Set 'until' to the end of yesterday (start of today in Unix seconds)
YESTERDAY_END=$(date -d "today 00:00:00" +%s)
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=1h&n=24&until=${YESTERDAY_END}"
```

### Last 7 days by day

```bash
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=1d&n=7"
```

### Last hour in 5-minute buckets

```bash
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=5m&n=12"
```

### Last 30 days in 6-hour buckets

```bash
curl "https://<your-gateway-host>/admin/v1/stats/timeseries?bucket=6h&n=120"
```

---

## See also

- [Logs API](logs.md)
- [Models & Pricing API](models.md)
- [Error Codes](error-codes.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
