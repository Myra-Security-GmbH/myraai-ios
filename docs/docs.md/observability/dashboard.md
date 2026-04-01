---
title: Admin dashboard
description: Overview of the AI Gateway admin dashboard — hero cards, timeframe selector, usage tables, and recent events.
---

# Admin dashboard

![View: Admin dashboard](../assets/screenshots/dashboard-overview.png)
*The admin dashboard showing hero cards, timeframe selector, usage tables, and recent events.*

The admin dashboard is the first screen shown after logging into the admin UI. It provides a live operations view of gateway activity: request volume, cost, guardrail hits, recent traffic, and recent blocked events.

---

## Timeframe selector

The top-right of the hero section contains the **Timeframe** drop-down list. Selecting a timeframe updates the hero card values and sparklines for that window.

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
|------|----------------|------------|
| Total Spend | Cumulative cost in USD | Cache savings in USD |
| Cache Savings | Cost avoided by serving cached responses | — |
| Total Requests | Total request count | Cache hit rate (%) |
| Error Rate | Percentage of requests with a 4xx/5xx upstream response | — |
| Top Spender | Tenant with the highest spend in the period | — |
| Budget Warnings | Number of tenants at or above 80 % of their configured budget | — |

---

## Usage by tenant

The **Usage by Tenant** table shows per-tenant activity for the selected timeframe. It is visible only when at least one request exists in the period.

| Column | Description |
|--------|-------------|
| Tenant | Tenant slug |
| Requests | Total requests |
| Input Tokens | Total input tokens consumed |
| Output Tokens | Total output tokens consumed |
| Cost | Total cost in USD |

---

## Top models

The **Top Models** table lists up to five models ordered by request count for the selected timeframe.

| Column | Description |
|--------|-------------|
| Provider | Provider slug |
| Model | Model name |
| Requests | Total requests to this model |
| Cost | Total cost in USD |
| Avg Latency | Average end-to-end latency in milliseconds |

---

## Recent requests

The **Recent Requests** table shows the last 20 requests across all gateways.

| Column | Description |
|--------|-------------|
| Time | Timestamp |
| Tenant | Tenant slug |
| Gateway | Gateway slug |
| Provider | Provider that handled the request |
| Model | Model name |
| Status | HTTP status code badge |
| Tokens | Input and output token counts (`in+out`) |
| Cost | Estimated cost in USD |
| Latency | End-to-end latency in milliseconds |
| Flags | `cached` or `blocked` badges where applicable |

---

## Recent guardrail events

The **Recent Guardrail Events** table shows the most recent blocked requests. It is visible only when blocked events exist.

| Column | Description |
|--------|-------------|
| Time | Timestamp |
| Tenant / Gateway | Routing context |
| Blocked by | Detector or guardrail that blocked the request |
| Reason | Block reason string |
| Provider | Intended provider |

!!! note "Refresh behaviour"
    The dashboard does not auto-refresh. Click the **Refresh** button to pull the latest data.

---

## See also

- [Cost analytics](analytics.md) — spend breakdown by tenant, gateway, provider, model, and user
- [Request logging](logging.md)
- [Request tracing](tracing.md)
- [Stats API](../api-reference/stats.md)
