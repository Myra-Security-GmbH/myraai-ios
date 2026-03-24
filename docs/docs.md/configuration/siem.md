# SIEM Integration

Stream AI gateway security events to an external Security Information and Event Management
(SIEM) system in real time. Supported backends: **Splunk HEC**, **Elasticsearch / OpenSearch**,
**Vector**, and **Syslog / CEF**.

---

## Overview

The gateway emits structured security telemetry for every blocked request, guardrail trigger, and
PII scrub event. SIEM integration forwards these events asynchronously — delivery happens on a
background timer and never adds latency to inference requests.

Typical SIEM use cases:

- **Threat detection** — correlate blocked requests across tenants or time windows
- **Compliance audit** — retain a tamper-evident log of all policy violations
- **Alerting** — trigger SIEM rules on jailbreak attempts, PII leakage, or budget anomalies

---

## Supported backends

| Type | Protocol | Auth | Best for |
|---|---|---|---|
| `splunk_hec` | HTTPS POST | Bearer token | Splunk Enterprise / Cloud |
| `elasticsearch` | HTTPS POST | Basic auth | Elasticsearch, OpenSearch |
| `vector` | HTTP POST | None | Vector sidecar fan-out (Loki, Datadog, S3…) |
| `syslog` | UDP or TCP | None | QRadar, ArcSight, CEF-native SIEMs |

---

## Configuration

SIEM config can be set at two levels:

- **Tenant level** — applies to all gateways under that tenant (default)
- **Gateway level** — overrides the tenant default for a specific gateway

### Tenant-level (default for all gateways)

```http
PATCH /admin/v1/tenants/{id}
Content-Type: application/json

{
  "siem": {
    "type": "splunk_hec",
    "url": "https://splunk.corp.com:8088/services/collector/event",
    "token": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "events": ["blocked", "guardrail"]
  }
}
```

To clear the tenant SIEM config, send `"siem": null`.

### Gateway-level (overrides tenant default)

```http
PATCH /admin/v1/gateways/{id}
Content-Type: application/json

{
  "config": {
    "siem": {
      "type": "syslog",
      "host": "siem.corp.com",
      "port": 514
    }
  }
}
```

When a gateway has `siem` in its config, it takes priority over the tenant-level setting.
To fall back to the tenant default, remove the `siem` key from the gateway config.

---

## Configuration reference

### Common fields

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Backend type: `splunk_hec`, `elasticsearch`, `vector`, `syslog` |
| `events` | array | No | Event filter (see [Event Filter](#event-filter)). Default: `["blocked"]` |

### Splunk HEC fields

| Field | Type | Required | Description |
|---|---|---|---|
| `url` | string | Yes | HEC endpoint, e.g. `https://splunk:8088/services/collector/event` |
| `token` | string | Yes | HEC token (sent as `Authorization: Splunk <token>`) |
| `index` | string | No | Target Splunk index. Omit to use the HEC default |

### Elasticsearch / OpenSearch fields

| Field | Type | Required | Description |
|---|---|---|---|
| `url` | string | Yes | Base URL, e.g. `https://es.corp.com:9200` |
| `index` | string | No | Index name. Default: `aig-logs` |
| `username` | string | No | Basic auth username |
| `password` | string | No | Basic auth password |

Documents are written to `<url>/<index>/_doc` (one document per event).

### Vector fields

| Field | Type | Required | Description |
|---|---|---|---|
| `url` | string | Yes | Vector HTTP source endpoint, e.g. `http://vector:8080` |

Configure Vector's [HTTP source](https://vector.dev/docs/reference/configuration/sources/http_server/)
to receive events. Vector can then fan out to any sink (Loki, Datadog, S3, Kafka, etc.).

### Syslog / CEF fields

| Field | Type | Default | Description |
|---|---|---|---|
| `host` | string | — | Syslog receiver hostname or IP |
| `port` | integer | `514` | Syslog receiver port |
| `protocol` | string | `udp` | Transport: `udp` or `tcp` |
| `format` | string | `cef` | Message format: `cef` (ArcSight CEF) or `rfc5424` |

---

## Event filter

The `events` array controls which request records are forwarded. Values can be combined.

| Value | Emits when… |
|---|---|
| `blocked` | Request was blocked for any reason (guardrail, rate limit, quota, IP allowlist) |
| `guardrail` | One or more detectors fired (block, flag, or scrub) |
| `scrubbed` | PII was tokenised and restored in the response |
| `all` | Every inference request, regardless of outcome |

**Default (no `events` key or empty array):** only `blocked` events are forwarded.

```json
{ "events": ["blocked", "guardrail"] }
```

!!! warning "Volume"
    `"all"` can produce very high volumes for busy gateways. Use a backend with
    adequate throughput (Elasticsearch, Vector) and configure appropriate index
    retention policies.

---

## Event payload

### HTTP backends (Splunk, Elasticsearch, Vector)

All HTTP backends receive the same structured fields from `request_log`:

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique request UUID |
| `tenant_id` | string | Tenant identifier |
| `gateway_id` | string | Gateway identifier |
| `provider` | string | LLM provider (openai, anthropic, …) |
| `model` | string | Model name |
| `status` | integer | HTTP status returned to the client |
| `blocked` | boolean | Whether the request was blocked |
| `blocked_by` | string | Block reason category (guardrail, rate_limit, quota, ip_allowlist) |
| `block_reason` | string | Human-readable block description |
| `detectors_fired` | array | Names of detectors that triggered |
| `guardrail_verdict` | string | Guardrail pipeline verdict |
| `scrub_applied` | boolean | Whether PII was scrubbed |
| `cost_usd` | number | Estimated inference cost |
| `latency_ms` | integer | End-to-end request latency |
| `input_tokens` | integer | Input token count |
| `output_tokens` | integer | Output token count |
| `user_id` | string | Associated user (if authenticated) |
| `token_label` | string | Auth token label |
| `ts` | integer | Unix milliseconds timestamp |

**Splunk HEC** wraps the fields under an `event` key with `time` and `sourcetype`:

```json
{
  "time": 1700000000.123,
  "sourcetype": "_json",
  "index": "ai-gateway",
  "event": { "id": "...", "tenant_id": "...", "blocked": true, ... }
}
```

**Elasticsearch and Vector** receive the raw fields object directly.

### Syslog / CEF format

CEF messages follow the ArcSight Common Event Format:

```
CEF:0|AI-Gateway|ai-gateway|1.0|GUARDRAIL_BLOCK|Request blocked by guardrail|7|
  src=<tenant_id> duser=<user_id>
  cs1Label=blocked_by cs1=guardrail
  cs2Label=block_reason cs2=keyword match: badword
  cs3Label=detectors cs3=keyword
  cs4Label=guardrail_verdict cs4=block
  cn1Label=status cn1=403
  cn2Label=cost_usd cn2=0.001
  cs5Label=provider cs5=openai
  cs6Label=model cs6=gpt-4o
```

RFC 5424 format wraps the raw JSON fields in a syslog envelope.

---

## Per-backend examples

### Splunk HEC

```json
{
  "siem": {
    "type": "splunk_hec",
    "url": "https://splunk.corp.com:8088/services/collector/event",
    "token": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "index": "ai-gateway-prod",
    "events": ["blocked", "guardrail"]
  }
}
```

### Elasticsearch

```json
{
  "siem": {
    "type": "elasticsearch",
    "url": "https://es.corp.com:9200",
    "index": "aig-logs",
    "username": "aig-writer",
    "password": "s3cr3t",
    "events": ["blocked", "scrubbed"]
  }
}
```

Recommended index mapping: use `keyword` for string fields and `date` with `format: epoch_millis`
for the `ts` field.

### Vector

```json
{
  "siem": {
    "type": "vector",
    "url": "http://vector.svc:8080",
    "events": ["all"]
  }
}
```

Vector config (excerpt):

```toml
[sources.aig]
type = "http_server"
address = "0.0.0.0:8080"
encoding.codec = "json"

[sinks.loki]
type = "loki"
inputs = ["aig"]
endpoint = "http://loki:3100"
```

### Syslog / CEF (UDP)

```json
{
  "siem": {
    "type": "syslog",
    "host": "siem.corp.com",
    "port": 514,
    "protocol": "udp",
    "format": "cef",
    "events": ["blocked"]
  }
}
```

### Syslog / RFC 5424 (TCP — for QRadar, IBM, etc.)

```json
{
  "siem": {
    "type": "syslog",
    "host": "qradar.corp.com",
    "port": 6514,
    "protocol": "tcp",
    "format": "rfc5424",
    "events": ["blocked", "guardrail"]
  }
}
```

---

## Configuring SIEM via the admin UI

1. Click on a gateway in the **Gateways** view.
   ↳ The gateway detail view opens.
2. Click on the **Edit** button.
   ↳ The gateway edit dialog opens.
3. Scroll to the **SIEM Integration** section.
4. Select a backend type from the **Type** drop-down list.
5. Select the events you want forwarded in the **Events** section.
6. Enter the backend-specific fields (URL, token, host/port).
7. To save the SIEM configuration, click on the **Save** button.
   ↳ The gateway forwards matching events to the configured SIEM backend.

To disable SIEM for a gateway, set the **Type** drop-down list back to **— disabled —** and click on **Save**. The gateway falls back to the tenant-level SIEM config (if any).

To configure a tenant-level default, use the API (`PATCH /admin/v1/tenants/{id}` with a
`"siem"` key). The admin UI tenant editor does not currently expose a SIEM section.

---

## See also

- [Guardrails](../security/guardrails.md) — configure the detector pipeline
- [Logs API](../api-reference/logs.md) — query request logs via REST
