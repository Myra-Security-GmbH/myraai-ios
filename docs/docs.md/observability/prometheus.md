# Prometheus Metrics

The gateway exposes a Prometheus-compatible metrics endpoint in text format 0.0.4.

---

## Endpoint

```
GET /metrics
```

The endpoint returns plain text in the standard Prometheus exposition format. It is **IP-restricted to `10.0.0.0/8` by default** — only requests from RFC 1918 private ranges are accepted.

```bash
curl https://<your-gateway-host>/metrics
```

---

## Available metrics

| Metric name | Type | Labels | Description |
|---|---|---|---|
| `aig_requests_total` | Counter | `provider`, `tenant_id`, `status`, `cached` | Total inference requests processed |
| `aig_latency_ms` | Histogram | `provider`, `tenant_id`, `status`, `cached` | End-to-end request latency in milliseconds |
| `aig_input_tokens_total` | Counter | `provider`, `tenant_id`, `status`, `cached` | Total input (prompt) tokens consumed |
| `aig_output_tokens_total` | Counter | `provider`, `tenant_id`, `status`, `cached` | Total output (completion) tokens generated |

### Label values

| Label | Example values |
|---|---|
| `provider` | `openai`, `anthropic`, `gemini`, `bedrock`, `groq`, … |
| `tenant_id` | UUID string |
| `status` | `200`, `429`, `500`, … |
| `cached` | `true`, `false` |

---

## Sample output

```
# HELP aig_requests_total Total inference requests processed
# TYPE aig_requests_total counter
aig_requests_total{provider="openai",tenant_id="t_abc",status="200",cached="false"} 1042
aig_requests_total{provider="anthropic",tenant_id="t_abc",status="200",cached="true"} 317
aig_requests_total{provider="openai",tenant_id="t_abc",status="429",cached="false"} 8

# HELP aig_latency_ms End-to-end request latency in milliseconds
# TYPE aig_latency_ms histogram
aig_latency_ms_bucket{provider="openai",...,le="100"} 120
aig_latency_ms_bucket{provider="openai",...,le="500"} 890
aig_latency_ms_bucket{provider="openai",...,le="1000"} 1038
aig_latency_ms_bucket{provider="openai",...,le="+Inf"} 1042
aig_latency_ms_sum{provider="openai",...} 423017
aig_latency_ms_count{provider="openai",...} 1042
```

---

## Adjusting scrape access

The `/metrics` endpoint is restricted by default. To adjust access permissions, contact your Myra Security account team.

!!! warning "Do not expose /metrics publicly"
    The metrics endpoint reveals tenant IDs, provider usage patterns, and request volumes. Keep it on a private network or add authentication if your scraper runs externally.

---

## Prometheus scrape config

Add this job to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: ai_gateway
    static_configs:
      - targets:
          - "<your-gateway-host>"
    metrics_path: /metrics
    scrape_interval: 15s
    scrape_timeout: 10s
```

If the gateway is on a different network from your Prometheus server, use a scrape proxy or ensure the scraping host's IP falls within the allowlist.

---

## Grafana dashboard notes

Useful queries and alert conditions:

### Error rate

```promql
sum(rate(aig_requests_total{status=~"5.."}[5m]))
  /
sum(rate(aig_requests_total[5m]))
```

Alert when this ratio exceeds `0.05` (5%) for more than 2 minutes.

### P95 latency

```promql
histogram_quantile(
  0.95,
  sum by (provider, le) (rate(aig_latency_ms_bucket[5m]))
)
```

Alert per-provider when P95 exceeds your SLA threshold (e.g. 3000 ms).

### Cache hit rate

```promql
sum(rate(aig_requests_total{cached="true"}[5m]))
  /
sum(rate(aig_requests_total[5m]))
```

### Token throughput

```promql
sum(rate(aig_input_tokens_total[1m])) by (provider)
sum(rate(aig_output_tokens_total[1m])) by (provider)
```

### Rate-limited requests

```promql
sum(rate(aig_requests_total{status="429"}[5m])) by (tenant_id)
```

Alert when any tenant exceeds a sustained rate-limited request rate.

---

## See also

- [Request Logging](logging.md)
- [Admin Dashboard](dashboard.md)
