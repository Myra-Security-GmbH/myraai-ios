# Request Tracing

Gateway tracing records a step-by-step execution trace for each inference request. Each trace captures what happened at every stage of the request pipeline — model resolution, routing decisions, guardrail results, upstream calls, and the final response delivered to the client. Traces are linked to log entries via the `trace_id` field.

Tracing is opt-in and has no effect on request latency — all writes are fire-and-forget.

---

## Enabling gateway tracing

Add a `tracing` block to your gateway config:

```json
{
  "tracing": {
    "enabled": true,
    "include_bodies": false
  }
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | boolean | `false` | Activate request tracing for this gateway. |
| `include_bodies` | boolean | `false` | Include the full message array from the request in the `request_received` step. Enable only for debugging — this stores prompt text in the trace table. |

Apply via the API:

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{"config": {"tracing": {"enabled": true}}}'
```

Or via the admin UI: open the gateway → **Config** tab → **Tracing** section.

---

## Pipeline step reference

Steps are recorded in sequence order. Only steps that are reached for a given request appear in the trace — a cached response, for example, will not have `upstream_request` or `upstream_response` steps.

### `request_received`

Recorded immediately after the request body is parsed.

| Field | Description |
|---|---|
| `model` | Model name as received from the client (before normalisation). |
| `provider` | Provider resolved from the URL path. |
| `messages_count` | Number of messages in the request body. |
| `streaming` | Whether the client requested a streaming response. |
| `size_bytes` | Raw request body size in bytes. |
| `is_compat` | Whether the request arrived on the OpenAI-compatible endpoint. |
| `messages` | Full message array (only present when `include_bodies: true`). |

---

### `request_transformed`

Recorded only when the model or provider changes during normalisation (e.g. compat endpoint provider inference, `ollama/` prefix stripping).

| Field | Description |
|---|---|
| `model_before` | Model name before normalisation. |
| `model_after` | Model name after normalisation. |
| `provider_before` | Provider before normalisation. |
| `provider_after` | Provider after normalisation. |

---

### `routing_applied`

Recorded when a routing rule matches and changes the provider or model.

| Field | Description |
|---|---|
| `rule_id` | ID of the matched routing rule. |
| `provider_before` | Provider before routing. |
| `model_before` | Model before routing. |
| `provider_after` | Provider after routing. |
| `model_after` | Model after routing. |

---

### `guardrail_result`

Recorded after the guardrail pipeline completes.

| Field | Description |
|---|---|
| `verdict` | `"safe"`, `"unsafe"`, or the guardrail verdict string. |
| `blocked` | `true` if the request was blocked. |
| `detector` | Name of the detector that fired (if blocked). |
| `latency_ms` | Time spent in the guardrail pipeline. |

---

### `upstream_request`

Recorded immediately before each upstream provider call.

| Field | Description |
|---|---|
| `attempt` | Attempt number (1 = first try). |
| `provider` | Provider being called. |
| `model` | Model being called. |
| `url` | Request URL sent to the provider (auth key stripped). |

---

### `upstream_response`

Recorded after each upstream provider response is received.

| Field | Description |
|---|---|
| `attempt` | Attempt number. |
| `provider` | Provider that responded. |
| `status` | HTTP status code. |
| `latency_ms` | Time between upstream request and response. |
| `input_tokens` | Prompt tokens from the provider usage object. |
| `output_tokens` | Completion tokens from the provider usage object. |

---

### `upstream_error`

Recorded when an upstream call fails with a network error (not an HTTP error response).

| Field | Description |
|---|---|
| `attempt` | Attempt number. |
| `provider` | Provider that failed. |
| `error` | Error message string. |

---

### `response_delivered`

Recorded after the response is sent to the client.

| Field | Description |
|---|---|
| `streaming` | Whether the response was streamed. |
| `provider_status` | HTTP status code from the upstream provider. |
| `body_size` | Response body size in bytes (non-streaming). |
| `compat` | Whether the response was re-encoded for the compat endpoint. |

---

### Web search steps (when web search is enabled)

| Step | Description |
|---|---|
| `leg1_request` | First inference call to extract search queries. |
| `leg1_response` | Response from the first call. |
| `leg1_direct_answer` | Recorded when the model answers directly without triggering a search. |
| `search_result` | Queries sent and snippets returned from the search provider. |
| `fetch_attempt` | URLs selected for full-page fetching. |
| `fetch_result` | Fetch outcome for each URL. |
| `leg2_request` | Second inference call with search context injected. |
| `leg2_response` | Final response from the second call. |

---

## Linking traces to log entries

When gateway tracing is enabled, each log entry contains a `trace_id` field. Use it to retrieve the full execution trace:

```bash
# 1. Fetch a log entry
curl "https://<your-gateway-host>/admin/v1/logs/log_abc789"
# → { "trace_id": "trc_abc123", ... }

# 2. Fetch the full trace
curl "https://<your-gateway-host>/admin/v1/traces/trc_abc123"
```

`trace_id` is `null` in log entries when tracing was not active for that request.

Playground requests always produce traces regardless of the gateway `tracing` config. Playground traces have `source: "playground"` and are accessible via the same `GET /traces/{id}` endpoint.

---

## See also

- [Traces API](../api-reference/traces.md)
- [Request Logging](logging.md)
- [Admin Dashboard](dashboard.md)
- [Gateway Configuration Reference](../reference/config-reference.md)
