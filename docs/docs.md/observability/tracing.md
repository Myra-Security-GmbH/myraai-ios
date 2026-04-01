---
title: Request tracing
description: What gateway tracing captures, the pipeline step reference, OpenTelemetry export configuration, and W3C traceparent propagation.
---

# Request tracing

Gateway tracing records a step-by-step execution trace for each inference request. Each trace captures what happened at every stage of the request pipeline — model resolution, routing decisions, guardrail results, upstream calls, and the final response delivered to the client. Traces are linked to log entries via the `trace_id` field.

Tracing is opt-in and has no effect on request latency. All writes are fire-and-forget.

---

## Enabling tracing

► Proceed as follows to enable tracing on a gateway:

1. Open the gateway in the admin UI.
   ⇒ The gateway detail page appears.
2. Click on the **Config** tab.
   ⇒ The gateway configuration panel opens.
3. Scroll to the **Tracing** section.
4. Toggle the **Enabled** control to on.
5. If required, toggle **Include bodies** to record the full message array in the `request_received` step.
   ⇒ Enable this for debugging only. It stores prompt text in the trace table.
6. Click the **Save** button.
   ⇒ The updated configuration is applied within seconds.

→ Tracing is active for all subsequent requests through this gateway.

Alternatively, apply the configuration via the API:

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{"config": {"tracing": {"enabled": true}}}'
```

The full tracing configuration block:

```json
{
  "tracing": {
    "enabled": true,
    "include_bodies": false
  }
}
```

| **Field** | **Type** | **Default** | **Description** |
|-----------|----------|-------------|-----------------|
| `enabled` | boolean | `false` | Activates request tracing for this gateway. |
| `include_bodies` | boolean | `false` | Includes the full message array from the request in the `request_received` step. Enable only for debugging — this stores prompt text in the trace table. |

---

## Pipeline step reference

Steps are recorded in sequence order. Only steps that are reached for a given request appear in the trace. For example, a cached response does not produce `upstream_request` or `upstream_response` steps.

### `request_received`

Recorded immediately after the request body is parsed.

| **Field** | **Description** |
|-----------|-----------------|
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

| **Field** | **Description** |
|-----------|-----------------|
| `model_before` | Model name before normalisation. |
| `model_after` | Model name after normalisation. |
| `provider_before` | Provider before normalisation. |
| `provider_after` | Provider after normalisation. |

---

### `routing_applied`

Recorded when a routing rule matches and changes the provider or model.

| **Field** | **Description** |
|-----------|-----------------|
| `rule_id` | ID of the matched routing rule. |
| `provider_before` | Provider before routing. |
| `model_before` | Model before routing. |
| `provider_after` | Provider after routing. |
| `model_after` | Model after routing. |

---

### `guardrail_result`

Recorded after the guardrail pipeline completes.

| **Field** | **Description** |
|-----------|-----------------|
| `verdict` | `"safe"`, `"unsafe"`, or the guardrail verdict string. |
| `blocked` | `true` if the request was blocked. |
| `detector` | Name of the detector that fired (if blocked). |
| `latency_ms` | Time spent in the guardrail pipeline. |

---

### `upstream_request`

Recorded immediately before each upstream provider call.

| **Field** | **Description** |
|-----------|-----------------|
| `attempt` | Attempt number (1 = first try). |
| `provider` | Provider being called. |
| `model` | Model being called. |
| `url` | Request URL sent to the provider (auth key stripped). |

---

### `upstream_response`

Recorded after each upstream provider response is received.

| **Field** | **Description** |
|-----------|-----------------|
| `attempt` | Attempt number. |
| `provider` | Provider that responded. |
| `status` | HTTP status code. |
| `latency_ms` | Time between upstream request and response. |
| `input_tokens` | Prompt tokens from the provider usage object. |
| `output_tokens` | Completion tokens from the provider usage object. |

---

### `upstream_error`

Recorded when an upstream call fails with a network error (not an HTTP error response).

| **Field** | **Description** |
|-----------|-----------------|
| `attempt` | Attempt number. |
| `provider` | Provider that failed. |
| `error` | Error message string. |

---

### `response_delivered`

Recorded after the response is sent to the client.

| **Field** | **Description** |
|-----------|-----------------|
| `streaming` | Whether the response was streamed. |
| `provider_status` | HTTP status code from the upstream provider. |
| `body_size` | Response body size in bytes (non-streaming). |
| `compat` | Whether the response was re-encoded for the compat endpoint. |

---

### Web search steps

These steps appear when web search is enabled on the gateway.

| **Step** | **Description** |
|----------|-----------------|
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

When gateway tracing is enabled, each log entry contains a `trace_id` field. Use it to retrieve the full execution trace.

► Proceed as follows to retrieve the trace for a log entry:

1. Fetch the log entry to obtain the `trace_id`.

   ```bash
   curl "https://<your-gateway-host>/admin/v1/logs/log_abc789"
   ```

   ⇒ The response contains a `trace_id` field, for example `"trc_abc123"`.

2. Fetch the full trace using the `trace_id`.

   ```bash
   curl "https://<your-gateway-host>/admin/v1/traces/trc_abc123"
   ```

→ The full execution trace for the request is returned.

> 💡 **Note:** `trace_id` is `null` in log entries when tracing was not active for that request.

Playground requests always produce traces regardless of the gateway `tracing` config. Playground traces have `source: "playground"` and are accessible via the same `GET /traces/{id}` endpoint.

---

## Configuring OTLP export

The gateway exports distributed traces as OpenTelemetry Protocol (OTLP) spans to any OpenTelemetry-compatible backend — Jaeger, Grafana Tempo, Datadog, Honeycomb, and others. OTLP export is independent of the internal pipeline trace described above.

### W3C traceparent propagation

The gateway reads an incoming `traceparent` header from the client (if present) and propagates the trace context to upstream LLM providers. This allows end-to-end trace correlation across your services, the gateway, and the provider. When the gateway initialises tracing for a request — whether from an incoming `traceparent` or by generating new IDs — it injects a `traceparent` header into the upstream provider request.

### OTLP/HTTP span export

After each request, the gateway emits a root span (SERVER) and, when an upstream call was made, a child span (CLIENT) to your OTel collector. Delivery is fully asynchronous and never adds latency.

### Configuration

Add `otlp_endpoint` to your existing `tracing` block:

```json
{
  "tracing": {
    "enabled": true,
    "otlp_endpoint": "http://otel-collector:4318",
    "service_name": "ai-gateway",
    "headers": {},
    "sample_rate": 1.0,
    "include_bodies": false
  }
}
```

| **Field** | **Type** | **Default** | **Description** |
|-----------|----------|-------------|-----------------|
| `enabled` | boolean | `false` | Activates internal pipeline tracing |
| `otlp_endpoint` | string | — | Base URL of your OTel collector, e.g. `http://otel-collector:4318`. Setting this enables OTLP export. |
| `service_name` | string | `ai-gateway` | `service.name` resource attribute on all emitted spans |
| `headers` | object | `{}` | Extra HTTP headers to include in the OTLP request (e.g. auth tokens for managed collectors) |
| `sample_rate` | number | `1.0` | Fraction of requests to export (0.0 = never, 1.0 = always) |
| `include_bodies` | boolean | `false` | When true, adds `aig.request_size_bytes` to spans |

> 💡 **Note:** `enabled: true` alone activates only the internal pipeline trace (playground / Traces API). Setting `otlp_endpoint` enables OTLP export and implies tracing is active for that gateway.

### Span model

Each exported trace contains up to two spans:

| **Span** | **Kind** | **When emitted** | **Name** |
|----------|----------|-----------------|----------|
| Root span | SERVER (2) | Every request | `inference` |
| Upstream span | CLIENT (3) | Only when an upstream LLM call was made | `upstream.<provider>` |

The `parentSpanId` of the upstream span is the `spanId` of the root span, forming a parent-child relationship.

### Root span attributes (GenAI semantic conventions)

| **Attribute** | **Type** | **Description** |
|---------------|----------|-----------------|
| `gen_ai.system` | string | LLM provider (`openai`, `anthropic`, …) |
| `gen_ai.request.model` | string | Model name |
| `gen_ai.usage.input_tokens` | integer | Prompt token count |
| `gen_ai.usage.output_tokens` | integer | Completion token count |
| `gen_ai.request.cost_usd` | double | Estimated inference cost |
| `http.status_code` | integer | HTTP status returned to the client |
| `aig.tenant_id` | string | Tenant identifier |
| `aig.gateway_id` | string | Gateway identifier |
| `aig.cached` | boolean | Whether the response came from cache |
| `aig.blocked` | boolean | Whether the request was blocked |
| `aig.blocked_by` | string | Block reason category (when blocked) |
| `aig.upstream_attempts` | integer | Number of upstream attempts (when > 1) |

### Upstream span attributes

| **Attribute** | **Type** | **Description** |
|---------------|----------|-----------------|
| `gen_ai.system` | string | Provider |
| `gen_ai.request.model` | string | Model |
| `http.status_code` | integer | Provider HTTP status |
| `aig.upstream_latency_ms` | integer | Provider round-trip latency |
| `aig.upstream_attempts` | integer | Retry count |
| `aig.fallback_provider` | string | Fallback provider (when failover occurred) |
| `aig.fallback_model` | string | Fallback model (when failover occurred) |

### Sampling

Use `sample_rate` to reduce export volume for high-traffic gateways:

```json
{ "tracing": { "otlp_endpoint": "http://otel:4318", "sample_rate": 0.1 } }
```

This exports roughly 10 % of requests. Sampling is applied after the request completes — the span is built and then discarded if the random draw exceeds `sample_rate`. There is no head-based sampling; every request processes normally.

### Configuration examples

The following examples show how to configure OTLP export for common backends.

**Jaeger (all-in-one)**

```json
{ "tracing": { "otlp_endpoint": "http://jaeger:4318" } }
```

**Grafana Tempo**

```json
{
  "tracing": {
    "otlp_endpoint": "http://tempo:4318",
    "service_name": "ai-gateway-prod"
  }
}
```

**Datadog OTLP endpoint**

```json
{
  "tracing": {
    "otlp_endpoint": "http://datadog-agent:4318",
    "headers": { "DD-API-KEY": "your-api-key" },
    "service_name": "ai-gateway"
  }
}
```

**Honeycomb**

```json
{
  "tracing": {
    "otlp_endpoint": "https://api.honeycomb.io",
    "headers": { "x-honeycomb-team": "your-api-key" },
    "service_name": "ai-gateway"
  }
}
```

---

## See also

- [Traces API](../api-reference/traces.md)
- [Request logging](logging.md)
- [Admin dashboard](dashboard.md)
- [Gateway configuration reference](../reference/config-reference.md)
