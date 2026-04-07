---
title: SIEM integration
description: Configure SIEM integration in AI Gateway by Myra Security. Supported backends, event payload structure, and gateway-level and tenant-level configuration.
---

# SIEM integration

SIEM integration streams AI gateway security events to an external Security Information and Event Management (SIEM) system in real time. The gateway emits structured security telemetry for every blocked request, guardrail trigger, and PII scrub event. Delivery happens on a background timer and never adds latency to inference requests.

Typical use cases:

- **Threat detection** — correlate blocked requests across tenants or time windows
- **Compliance audit** — retain a tamper-evident log of all policy violations
- **Alerting** — trigger SIEM rules on jailbreak attempts, PII leakage, or budget anomalies

## Supported backends

| **Type** | **Protocol** | **Auth** | **Best for** |
|---|---|---|---|
| `splunk_hec` | HTTPS POST | Bearer token | Splunk Enterprise / Cloud |
| `elasticsearch` | HTTPS POST | Basic auth | Elasticsearch, OpenSearch |
| `vector` | HTTP POST | None | Vector sidecar fan-out (Loki, Datadog, S3…) |
| `syslog` | UDP or TCP | None | QRadar, ArcSight, CEF-native SIEMs |

## Configuration levels

SIEM config is set at two levels:

- **Tenant level** — applies to all gateways under that tenant by default.
- **Gateway level** — overrides the tenant default for a specific gateway.

When a gateway has a `siem` key in its config, it takes priority over the tenant-level setting. To fall back to the tenant default, remove the `siem` key from the gateway config.

## Configuration fields reference

### Common fields

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `type` | string | Yes | Backend type: `splunk_hec`, `elasticsearch`, `vector`, `syslog` |
| `events` | array | No | Event filter. Default: `["blocked"]`. See [Event filter](#event-filter). |

### Splunk HEC fields

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `url` | string | Yes | HEC endpoint, e.g. `https://splunk:8088/services/collector/event` |
| `token` | string | Yes | HEC token (sent as `Authorization: Splunk <token>`) |
| `index` | string | No | Target Splunk index. Omit to use the HEC default. |

### Elasticsearch / OpenSearch fields

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `url` | string | Yes | Base URL, e.g. `https://es.corp.com:9200` |
| `index` | string | No | Index name. Default: `aig-logs` |
| `username` | string | No | Basic auth username |
| `password` | string | No | Basic auth password |

Documents are written to `<url>/<index>/_doc` (one document per event).

### Vector fields

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `url` | string | Yes | Vector HTTP source endpoint, e.g. `http://vector:8080` |

Configure the [HTTP source](https://vector.dev/docs/reference/configuration/sources/http_server/) of Vector to receive events. Vector can then fan out to any sink (Loki, Datadog, S3, Kafka, etc.).

### Syslog / CEF fields

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `host` | string | — | Syslog receiver hostname or IP |
| `port` | integer | `514` | Syslog receiver port |
| `protocol` | string | `udp` | Transport: `udp` or `tcp` |
| `format` | string | `cef` | Message format: `cef` (ArcSight CEF) or `rfc5424` |

## Event filter

The `events` array controls which request records are forwarded. Values can be combined.

| **Value** | **Emits when** |
|---|---|
| `blocked` | Request was blocked for any reason (guardrail, rate limit, quota, IP allowlist) |
| `guardrail` | One or more detectors fired (block, flag, or scrub) |
| `scrubbed` | PII was tokenised and restored in the response |
| `all` | Every inference request, regardless of outcome |

Default (no `events` key or empty array): only `blocked` events are forwarded.

```json
{ "events": ["blocked", "guardrail"] }
```

> ⚠️ **Caution:** `"all"` produces very high volumes for busy gateways. Use a backend with adequate throughput (Elasticsearch, Vector) and configure appropriate index retention policies.

## Event payload

### HTTP backends (Splunk, Elasticsearch, Vector)

All HTTP backends receive the same structured fields from `request_log`:

| **Field** | **Type** | **Description** |
|---|---|---|
| `id` | string | Unique request UUID |
| `tenant_id` | string | Tenant identifier |
| `gateway_id` | string | Gateway identifier |
| `provider` | string | LLM provider (`openai`, `anthropic`, …) |
| `model` | string | Model name |
| `status` | integer | HTTP status returned to the client |
| `blocked` | boolean | Whether the request was blocked |
| `blocked_by` | string | Block reason category (`guardrail`, `rate_limit`, `quota`, `ip_allowlist`) |
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
  "event": { "id": "...", "tenant_id": "...", "blocked": true }
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

## Per-backend configuration examples

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

Recommended index mapping: use `keyword` for string fields and `date` with `format: epoch_millis` for the `ts` field.

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

## Configuring gateway-level SIEM integration

Use gateway-level SIEM integration to override the tenant default for a specific gateway, or to configure SIEM on a gateway that has no tenant-level setting.

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

![Screenshot: Gateway edit dialog with SIEM Integration section](../assets/screenshots/gateway-siem.png)
*The **SIEM Integration** section in the gateway edit dialog.*

► Proceed as follows to configure gateway-level SIEM integration:

1. Click on **Gateways** in the left sidebar.
   - The **Gateways** list opens.
2. Click on the gateway.
   - The gateway detail view opens.
3. Click on the **Edit** button.
   - The gateway edit dialog opens.
4. Scroll to the **SIEM Integration** section.
5. Select a backend type from the **Type** drop-down list.
6. Select the events you want forwarded in the **Events** section.
7. Enter the backend-specific fields (URL, token, host/port) as shown in the [Per-backend configuration examples](#per-backend-configuration-examples).
8. Click on the **Save** button.
   - The gateway forwards matching events to the configured SIEM backend.

→ The gateway-level SIEM configuration is active. It overrides the tenant default for this gateway.

> 💡 **Note:** To disable SIEM for a gateway and fall back to the tenant-level config, set the **Type** drop-down list to **— disabled —** and click on **Save**.

---

## Configuring tenant-level SIEM integration

The tenant-level SIEM configuration applies to all gateways under the tenant that do not have a gateway-level override. The admin UI tenant editor does not expose a SIEM section — use the API.

► Proceed as follows to configure tenant-level SIEM integration:

1. Send a `PATCH` request to `/admin/v1/tenants/{id}` with the `siem` object in the request body:

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

   - The tenant SIEM configuration is saved.

→ All gateways under the tenant forward matching events to the configured SIEM backend, unless they have a gateway-level override.

> 💡 **Note:** To clear the tenant SIEM configuration, send `"siem": null` in the PATCH request body.

---

## See also

- [Guardrails](../security/guardrails.md) — configure the detector pipeline
- [Logs API](../api-reference/logs.md) — query request logs via REST
