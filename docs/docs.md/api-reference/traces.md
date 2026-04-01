# Traces API

The Traces API exposes execution traces recorded by the gateway for individual inference requests. Gateway traces capture the same step-by-step pipeline detail as Playground traces and are linked to log entries via the `trace_id` field.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## GET /gateways/{id}/traces

Returns recent gateway-level execution traces for a gateway, ordered newest-first.

```bash
curl "https://<your-gateway-host>/admin/v1/gateways/gw_xyz789/traces?limit=50"
```

### Query parameters

| **Parameter** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `limit` | integer | `50` | Maximum number of traces to return. Range: 1–200. |

### Response

An array of trace summary objects:

| **Field** | **Type** | **Description** |
|---|---|---|
| `id` | string | Trace UUID. Use with `GET /traces/{id}` to fetch full detail. |
| `model` | string | Model used for this request. |
| `created_at` | integer | Trace start time as Unix seconds. |
| `completed_at` | integer \| null | Trace end time as Unix seconds. `null` if still running. |
| `status` | string | One of `running`, `done`, `error`. |
| `error` | string \| null | Error message if `status` is `error`. |
| `source` | string | Always `gateway` for traces returned by this endpoint. |

### Example response

```json
[
  {
    "id": "trc_abc123",
    "model": "gpt-4o",
    "created_at": 1742547600,
    "completed_at": 1742547601,
    "status": "done",
    "error": null,
    "source": "gateway"
  },
  {
    "id": "trc_def456",
    "model": "claude-opus-4-6",
    "created_at": 1742547580,
    "completed_at": null,
    "status": "running",
    "error": null,
    "source": "gateway"
  }
]
```

---

## GET /traces/{id}

Fetches the full detail of any trace — gateway or Playground — by its ID. Returns the trace metadata alongside an ordered list of pipeline steps.

```bash
curl "https://<your-gateway-host>/admin/v1/traces/trc_abc123"
```

### Response structure

```json
{
  "trace": { ...TraceObject },
  "steps": [ ...StepObject ]
}
```

### TraceObject fields

| **Field** | **Type** | **Description** |
|---|---|---|
| `id` | string | Trace UUID. |
| `model` | string | Model used. |
| `created_at` | integer | Trace start time as Unix seconds. |
| `completed_at` | integer \| null | Trace end time. `null` if still running. |
| `status` | string | One of `running`, `done`, `error`. |
| `error` | string \| null | Error message, if any. |
| `source` | string | `gateway` or `playground`. |

### StepObject fields

| **Field** | **Type** | **Description** |
|---|---|---|
| `seq` | integer | Step sequence number (1-based, ascending). |
| `step` | string | Step name identifying the pipeline stage (e.g. `auth`, `guardrail`, `upstream`, `log`). |
| `data` | object | Step-specific structured data (decoded from JSON). Content varies by step type. |

### Example response

```json
{
  "trace": {
    "id": "trc_abc123",
    "model": "gpt-4o",
    "created_at": 1742547600,
    "completed_at": 1742547601,
    "status": "done",
    "error": null,
    "source": "gateway"
  },
  "steps": [
    {
      "seq": 1,
      "step": "auth",
      "data": { "token_id": "tok_xyz", "tenant": "myapp" }
    },
    {
      "seq": 2,
      "step": "upstream",
      "data": {
        "provider": "openai",
        "model": "gpt-4o",
        "latency_ms": 780,
        "status": 200
      }
    },
    {
      "seq": 3,
      "step": "log",
      "data": {
        "cost_usd": 0.00448,
        "input_tokens": 512,
        "output_tokens": 128
      }
    }
  ]
}
```

Returns `404` if no trace with the given ID exists.

---

## Linking traces to log entries

When gateway tracing is enabled, each request log entry includes a `trace_id` field. Use it to look up the corresponding full trace:

```bash
# 1. Fetch a log entry
curl "https://<your-gateway-host>/admin/v1/logs/log_abc789"
# → { "trace_id": "trc_abc123", ... }

# 2. Fetch the full trace
curl "https://<your-gateway-host>/admin/v1/traces/trc_abc123"
```

When `trace_id` is `null` in a log entry, gateway tracing was not active for that request.

---

## See also

- [Logs API](logs.md)
- [Stats API](stats.md)
- [Gateway Configuration Reference](../reference/config-reference.md)
