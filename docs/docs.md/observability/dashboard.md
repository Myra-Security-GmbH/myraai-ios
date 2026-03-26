# Admin Dashboard

The dashboard is the first screen shown after logging into the admin UI. It provides a live operations view of real-time gateway activity: request volume, cost, guardrail hits, recent traffic, and recent blocked events.

---

![Dashboard overview](../assets/screenshots/dashboard-overview.png)

## Timeframe selector

The top-right of the hero section contains a timeframe selector. Choosing a timeframe updates the hero card values and sparklines for that window.

| Option | Window |
|--------|--------|
| Today | From midnight UTC to now |
| Yesterday | The previous calendar day |
| Last 7 days | Rolling 7-day window |
| Last hour | Rolling 60-minute window |
| Last minute | Rolling 60-second window |

---

## Hero cards

Six cards summarise the selected timeframe at a glance. Each card includes a sparkline chart of the underlying timeseries.

| Card | Primary metric | Sub-metric |
|------|---------------|------------|
| Total Spend | Cumulative cost in USD | Cache savings in USD |
| Cache Savings | Cost avoided by serving cached responses | — |
| Total Requests | Total request count | Cache hit rate (%) |
| Error Rate | Percentage of requests with a 4xx/5xx upstream response | — |
| Top Spender | Tenant with the highest spend in the period | — |
| Budget Warnings | Number of tenants at or above 80 % of their configured budget | — |

---

## Usage by Tenant

A table showing per-tenant activity for the selected timeframe:

| Column | Description |
|--------|-------------|
| Tenant | Tenant slug |
| Requests | Total requests |
| Input Tokens | Total input tokens consumed |
| Output Tokens | Total output tokens consumed |
| Cost | Total cost in USD |

Only visible when there is at least one request in the period.

---

## Top Models

A table of up to 5 models ordered by request count for the selected timeframe:

| Column | Description |
|--------|-------------|
| Provider | Provider slug |
| Model | Model name |
| Requests | Total requests to this model |
| Cost | Total cost in USD |
| Avg Latency | Average end-to-end latency in milliseconds |

---

## Recent Requests

A live table of the last 20 requests across all gateways:

| Column | Description |
|--------|-------------|
| Time | Timestamp |
| Tenant | Tenant slug |
| Gateway | Gateway slug |
| Provider | Provider that handled the request |
| Model | Model name |
| Status | HTTP status code badge |
| Tokens | Input + output token counts (`in+out`) |
| Cost | Estimated cost in USD |
| Latency | End-to-end latency in milliseconds |
| Flags | `cached` or `blocked` badges where applicable |

---

## Recent Guardrail Events

A table of the most recent blocked requests. Only shown when blocked events exist.

| Column | Description |
|--------|-------------|
| Time | Timestamp |
| Tenant / Gateway | Routing context |
| Blocked by | Detector or guardrail that blocked the request |
| Reason | Block reason string |
| Provider | Intended provider |

!!! note "Refresh behaviour"
    The dashboard does not auto-refresh. Click the refresh button to pull the latest data.

---

## See also

- [Cost Analytics](analytics.md) — spend breakdown by tenant, gateway, provider, model, and user
- [Request Logging](logging.md)
- [Request Tracing](tracing.md)
- [Stats API](../api-reference/stats.md)
