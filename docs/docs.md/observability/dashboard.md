# Admin Dashboard

The dashboard is the first screen shown after logging into the admin UI. It provides a real-time summary of gateway activity: request volume, cost, blocked requests, and recent traffic.

---

## Hero cards

Three hero cards appear at the top of the dashboard, each covering a key operational dimension.

| Card | Primary metric | Sub-metric |
|---|---|---|
| Requests | Total requests in the selected period | Cache hit rate (%) |
| Cost | Total spend in USD | Cache savings in USD |
| Blocked | Total blocked requests | Block rate (%) |

Each card contains an inline SVG sparkline that mirrors the chart for the selected timeframe. The sparkline updates when the timeframe switcher is changed.

---

## Timeframe switcher

| Label | Chart granularity | Data points |
|---|---|---|
| Today | 1-hour buckets | Hours elapsed so far today |
| Yesterday | 1-hour buckets | 24 |
| Last 7 days | 1-day buckets | 7 |
| Last hour | 5-minute buckets | 12 |
| Last minute | 5-minute buckets | 12 |

Selecting a timeframe triggers two API calls in parallel:

- `GET /admin/v1/stats` — aggregate totals for the period (feeds hero cards)
- `GET /admin/v1/stats/timeseries` — bucketed series data (feeds sparklines and the main chart)

The dashboard continues to display the last available data if a metric fetch is temporarily unavailable.

---

## Underlying APIs

### Aggregates

```
GET /admin/v1/stats?from=<iso>&to=<iso>
```

Returns totals for the period:

```json
{
  "requests":       1423,
  "cached":          317,
  "cache_hit_rate":  0.223,
  "cost_usd":        4.81,
  "saved_cost_usd":  0.94,
  "blocked":          12,
  "block_rate":       0.008
}
```

### Timeseries

```
GET /admin/v1/stats/timeseries?from=<iso>&to=<iso>&bucket=1h
```

The `bucket` parameter specifies the bucket size using a string shorthand (`5m`, `15m`, `30m`, `1h`, `6h`, `1d`).

Returns an array of time buckets:

```json
{
  "buckets": [
    {"ts": "2025-01-01T00:00:00Z", "requests": 82, "cost_usd": 0.21, "blocked": 0},
    {"ts": "2025-01-01T01:00:00Z", "requests": 95, "cost_usd": 0.24, "blocked": 1},
    ...
  ]
}
```

---

## By Tenant table

Below the hero cards, a table shows today's usage broken down by tenant:

| Column | Description |
|---|---|
| Tenant | Tenant slug |
| Requests | Total requests today |
| Cost | Total cost today in USD |
| Cached | Cache hit count |
| Blocked | Blocked request count |

---

## Recent Requests table

A live table of the last N requests (default 20):

| Column | Description |
|---|---|
| Time | Timestamp (relative, e.g. "2 min ago") |
| Tenant / Gateway | Routing context |
| Provider | Provider that handled the request |
| Model | Model name |
| Status | HTTP status code badge |
| Tokens | Input + output token counts |
| Cost | Estimated cost |
| Latency | End-to-end latency in ms |

Clicking a row opens the full log entry in a side panel, including prompt and response text (if payload logging is enabled).

---

## Recently Blocked table

A filtered view of the most recent blocked requests:

| Column | Description |
|---|---|
| Time | Timestamp |
| Tenant / Gateway | Routing context |
| Blocked by | Detector or guardrail name |
| Reason | Block reason string |
| Provider | Intended provider |

!!! note "Refresh behaviour"
    The dashboard does not auto-refresh. Click the refresh button or switch timeframes to pull the latest data.

---

## See also

- [Request Logging](logging.md)
- [Prometheus Metrics](prometheus.md)
- [Admin UI Overview](../admin-ui/overview.md)
