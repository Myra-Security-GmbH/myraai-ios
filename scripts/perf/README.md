# AI Gateway — Performance Test Suite

Measures latency and throughput for **qwen3-30b-a3b** (local vLLM) and the
**PII guardrail overhead** to estimate max concurrent user capacity on the current hardware.

---

## Quick start

```bash
cd /home/sas/work/ai-gateway

# 1. Generate synthetic prompt corpus (one-time, ~5 s)
python3 scripts/perf/gen_prompts.py --output scripts/perf/prompts.jsonl

# 2. Quick smoke test (Scenario A only, 10 requests, no warm-up)
python3 scripts/perf/run_perf.py --scenarios A --n 10 --no-warmup

# 3. Full suite (uses session cookie to auto-fetch playground tokens)
python3 scripts/perf/run_perf.py

# 4. View the report
cat results/report_*.md
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Python 3.10+ | `python3 --version` |
| httpx | `pip3 install httpx` |
| Playwright session | `frontend/tests/.auth/docker-session.json` must exist (run E2E auth setup) |
| Prompt corpus | `scripts/perf/prompts.jsonl` (generate with `gen_prompts.py`) |
| vLLM running | `curl -s http://172.28.0.1:8003/v1/models` must return `qwen3-30b-a3b` |

**Optional: dedicated test token** (recommended for Scenarios B and H)

Create a gateway token with a high rate limit (10,000 req/min) in the admin UI so
the 500 req/min production limit doesn't interfere with throughput measurements.

```bash
python3 scripts/perf/run_perf.py --token YOUR_TEST_TOKEN
```

---

## Scenarios

| ID | Name | Purpose |
|---|---|---|
| A | Sequential baseline | p50/p95/p99 at concurrency=1 (zero queue) |
| B | Concurrency ramp | Throughput ceiling; finds "knee" where latency doubles |
| C | Guardrail A/B | Measures PII guardrail overhead in isolation |
| D | Cache effectiveness | Measures cache hit rate and latency saving |
| E | Streaming TTFT | Time-to-first-token at different concurrency levels |
| F | Direct vLLM baseline | Bypass gateway to isolate gateway overhead |
| G | Long context stress | 8,000-token inputs; tests KV cache pressure |
| H | Rate limit boundary | Finds concurrency that triggers 429 responses |

Run a subset: `--scenarios A,B,C`

---

## Important measurement notes

**TTFT is measured correctly**: the gateway compat endpoint emits an empty role-delta
chunk first (before any vLLM data). The runner parses each SSE chunk's JSON and
timestamps the first one where `choices[0].delta.content` is non-empty.

**Throughput formula**: `len(results) / (max_end_time - min_start_time)`, not
`sum_of_latencies / n`. These differ significantly at high concurrency.

**vLLM hard limit**: `--max-num-seqs 32` means the engine handles at most 32 in-flight
requests. The ramp stops automatically at that ceiling or earlier if p95 > 15 s.

---

## Output files

All output goes to `results/` (auto-created):

| File | Contents |
|---|---|
| `perf_YYYYMMDD_HHMMSS.jsonl` | Raw measurements (one JSON per request) |
| `vllm_metrics_SCENARIO.jsonl` | vLLM Prometheus metrics polled every 5 s |
| `report_YYYYMMDD_HHMMSS.md` | Markdown summary with capacity estimate |

---

## vLLM metrics (optional, parallel polling)

In a separate terminal during the test run:

```bash
python3 scripts/perf/poll_vllm_metrics.py --output results/vllm_metrics_run1.jsonl
```

Captures: GPU KV cache utilisation, requests running/waiting, decode tps, TTFT histogram.

---

## Re-analysing results

```bash
python3 scripts/perf/analyse.py results/perf_20260422_123456.jsonl
python3 scripts/perf/analyse.py results/perf_20260422_123456.jsonl --format markdown
```

---

## Hardware context

| Component | Value |
|---|---|
| Model | qwen3-30b-a3b (MoE, 3B active / 30B total params, AWQ quantized) |
| GPU (qwen3) | NVIDIA RTX PRO 6000 Blackwell, 97 GB VRAM |
| vLLM max-num-seqs | **32** (hard concurrency ceiling) |
| vLLM chunked prefill | enabled |
| KV cache dtype | fp8 (memory efficient) |
| Gateway workers | 16 nginx workers |
| Rate limit | 500 req/min per token (per-worker shared dict, not global) |

---

## Interpreting the capacity estimate

The report outputs:
- **Comfortable capacity**: highest concurrency where p95 < 10 s (good interactive UX)
- **Hard ceiling**: highest concurrency where error rate < 2%

These are **concurrent in-flight requests**, not concurrent users. To convert:

```
max_users ≈ max_concurrent_requests × (1 + think_time_s / mean_latency_s)
```

A user who sends a message every 60 s with a 2.65 s response time would contribute
`2.65 / (60 + 2.65) ≈ 4.2%` of a "concurrent slot". So if the comfortable capacity is
8 concurrent requests, that supports roughly `8 / 0.042 ≈ 190 active users`
(users who send at least one message every minute).
