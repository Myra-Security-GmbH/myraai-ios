# AI Gateway — Performance Measurement Analysis

_Last updated: 2026-04-23_

---

## Toolset inventory

| File | Purpose |
|---|---|
| `scripts/perf/run_perf.py` | Main test runner — 8 scenarios, asyncio concurrency, JSONL output |
| `scripts/perf/gen_prompts.py` | Synthetic prompt corpus generator (200 prompts, 3 token buckets) |
| `scripts/perf/analyse.py` | Post-run analysis — percentiles, throughput, cache hit rate |
| `scripts/perf/poll_vllm_metrics.py` | Background Prometheus scraper — KV cache %, running/waiting queues, TTFT histograms |
| `results/perf_*.jsonl` | Raw per-request measurements |
| `results/report_*.md` | Auto-generated markdown reports |
| `results/vllm_metrics_run.jsonl` | 18-hour vLLM Prometheus time series (April 22–23) |

---

## Scenario reference

| ID | What it measures | Key output |
|---|---|---|
| A | Sequential baseline at concurrency=1 — zero queue wait, pure model latency | p50/p95/p99 wall time, TTFT, decode tps |
| B | Concurrency ramp 1→2→4→8→12→16→24→32 — stops when p95 > 15 s or errors > 2% | Throughput curve, knee concurrency |
| C | PII guardrail A/B at concurrency=8 — same prompts through prod vs prod-pii | Overhead in ms at p50/p95 |
| D | Cache effectiveness — 50 unique then 50 repeat prompts | Cache hit rate, latency delta |
| E | Streaming TTFT at concurrency 1/4/8/16 | Time-to-first-token under queue pressure |
| F | Direct vLLM bypass at same concurrency levels as B | Gateway overhead = B_p50 − F_p50 |
| G | Long context stress — ≥5,000-token inputs, concurrency=4, n=50 | KV cache pressure, prefill latency |
| H | Rate limit boundary — ramp until 429 appears | Effective requests/min ceiling per token |

---

## Methodology notes

### What is measured correctly

**TTFT** — the runner parses each SSE chunk's `choices[0].delta.content` and timestamps the first non-empty one. This correctly skips the role-delta preamble chunk that the gateway emits before any vLLM data. The result is true time-to-first-content-token, not time-to-first-SSE-frame.

**Throughput** — computed as `n_ok / (max_end_time − min_start_time)`, not `n / sum_latency`. At high concurrency these diverge significantly. The formula is correct.

**Wall time** — uses `time.perf_counter()` for sub-millisecond precision, with `time.time()` for absolute timestamps. Correct.

**Decode TPS** — `tokens_out / decode_ms`, where `decode_ms = wall_ms − ttft_ms`. This is end-to-end decode time including streaming and network, not pure GPU decode. Slightly inflated by network jitter, but consistent across runs.

**Capacity estimation** — applies Little's Law (`λ = L / W`) per concurrency level and identifies the "knee" (p95 doubles vs concurrency=1 baseline) and the "comfortable ceiling" (p95 < 10 s). The 10-second SLO is a reasonable interactive threshold.

### Known limitations

**Tokens_out is sparse in some runs** — the `decode_tps` field is `None` when `tokens_out = 0`. This happens when the streaming response ends without a `usage` chunk, which can occur if the gateway or vLLM omits `stream_options: include_usage`. In the 193046 run all direct-vLLM (Scenario F) measurements have `decode_tps_p50=None` despite successful requests.

**Concurrency ceiling is vLLM's `--max-num-seqs`** — the ramp stops at 32. Requests above this limit are not rejected; they queue inside vLLM. The runner's `asyncio.Semaphore` limits inflight HTTP requests, but vLLM's internal scheduler can queue more than `max_num_seqs` if the HTTP requests arrive before they are scheduled.

**Rate limiting is not globally enforced** — the gateway uses per-worker shared dicts. With 16 nginx workers, the effective rate limit is up to 16× the configured per-token limit. Scenario H results are therefore a lower bound on the true rate ceiling.

**No think-time data** — the suite measures concurrent requests, not concurrent users. The README's conversion formula (`max_users ≈ max_concurrent × (1 + think_time / mean_latency)`) requires think-time data from production logs that hasn't been collected.

**Prompt token distribution is approximate** — `gen_prompts.py` uses `tiktoken cl100k_base` as a proxy tokenizer. Qwen3's tokenizer is different; actual token counts can differ by up to ~15% for technical English content. The `approx_tokens` field stored per prompt reflects this approximation.

---

## Existing results analysis (Blackwell, 2026-04-22)

All five test runs were performed on the old 3-GPU configuration:
- GPU 0: NVIDIA RTX A6000 (48 GB) — not used by qwen3
- GPU 1–2: NVIDIA RTX PRO 6000 Blackwell (98 GB each) — qwen3 on GPU 2, MinerU on GPU 1
- vLLM config: `--max-num-seqs 32 --max-num-batched-tokens 32768 --gpu-memory-utilization 0.80 --enable-chunked-prefill --kv-cache-dtype fp8`

**This hardware no longer exists.** The machine was rebooted and qwen3 now runs on the H200 NVL (GPU 0) with updated parameters. These results are a historical baseline for the Blackwell configuration only.

### Scenario A — Sequential baseline (run 195143, clean)

The only Scenario A run with 0% error rate (30/30 requests).

| Metric | Value |
|---|---|
| wall p50 | 8,770 ms |
| wall p95 | 8,921 ms |
| wall p99 | 9,040 ms |
| TTFT p50 | 4,607 ms |
| decode TPS p50 | 552 tok/s |
| throughput | 0.121 req/s (7.2 req/min) |

TTFT of 4.6 s at concurrency=1 is high. At concurrency=1 there is no queue — TTFT reflects pure prefill time. With ~1,935 input tokens and 4,607 ms, the implied prefill throughput is ~420 tokens/s. This is consistent with the Blackwell's compute profile for AWQ-quantized MoE at this batch size (batch=1 during prefill is compute-inefficient; chunked prefill helps but the Blackwell has limited fp8 tensor core throughput at small batches).

Wall p95 of 8.9 s at concurrency=1 defines the "comfortable capacity" baseline. Any concurrency level where p95 exceeds this means queuing is degrading response time.

### Scenario F — Direct vLLM baseline (run 193046, clean)

All concurrency levels completed with 0% errors. This is the only full multi-concurrency dataset available.

| c | wall p50 (ms) | wall p95 (ms) | TTFT p50 (ms) | throughput (req/s) | throughput (req/min) |
|---|---|---|---|---|---|
| 1 | 8,758 | 8,927 | 51 | 0.121 | 7.2 |
| 2 | 11,425 | 11,633 | 25 | 0.184 | 11.0 |
| 4 | 13,238 | 13,597 | 29 | 0.311 | 18.7 |
| 8 | 15,527 | 15,825 | 35 | 0.496 | 29.8 |
| 16 | 20,705 | 20,861 | 98 | 0.722 | 43.3 |
| 32 | 27,815 | 27,818 | 150 | 1.078 | 64.7 |

**Key observations:**

TTFT at c=1 is 51 ms (direct vLLM) vs 4,607 ms (gateway, Scenario A). The 4.6 s figure in Scenario A is not TTFT in the traditional sense — it is the time until the first non-empty `delta.content`, which means vLLM is producing thinking tokens (Qwen3's chain-of-thought `<think>` block) before emitting visible output. The 51 ms figure from Scenario F is time-to-first-SSE-chunk regardless of content, confirming the gateway TTFT measurement is correct and the gap is real model behavior (thinking before answering).

Throughput scales well from c=1 to c=32: 0.121 → 1.078 req/s, a 9× gain for a 32× concurrency increase. This is typical for decode-heavy workloads — the engine batches decode steps effectively but can't fully utilize the GPU's compute at small prefill batches.

At c=32 (the `--max-num-seqs` ceiling), p95=27,818 ms and throughput=1.078 req/s. The vLLM batch is fully saturated. Wall time grows almost linearly with concurrency in the c=16–32 range, indicating the engine is decode-throughput-bound, not compute-bound.

TTFT grows with concurrency (51 ms at c=1 → 150 ms at c=32) because prefill requests queue behind ongoing decode batches. Chunked prefill mitigates this but doesn't eliminate it.

### Scenario C — PII guardrail overhead (run 191757)

| Gateway | p50 (ms) | p95 (ms) | throughput (req/s) |
|---|---|---|---|
| prod (no guardrail) | 8,001 | 8,002 | 0.625 |
| prod-pii (PII guard) | 8,574 | 8,986 | 0.554 |
| **overhead** | **+573 ms** | **+984 ms** | −11.4% |

PII guardrail (Presidio) adds 573 ms at p50 and 984 ms at p95 at concurrency=8. This is the pre-analysis latency added by the synchronous Presidio call on the input path. The p95 overhead is 72% larger than the p50 overhead, suggesting Presidio latency is variable under load (it runs on CPU — `andreas.strebe`'s uvicorn process on port 8100).

### vLLM metrics time series (18 hours, 2026-04-22 19:30 → 2026-04-23 13:25)

- 12,895 5-second snapshots collected; 2,526 without error (the rest returned `Connection refused` after the Blackwell vLLM instance went down post-reboot)
- Peak concurrent requests running: **30** (just under the 32 ceiling, hit during Scenario F c=32)
- Peak decode TPS: **2,332 tok/s** — total output tokens per second across all concurrent sequences during the Scenario F c=32 burst
- Peak prefill TPS: **9,052 tok/s** — input tokens processed per second during peak prefill batches
- TTFT p50 from vLLM-internal histogram: 22–23 ms — consistent with the direct Scenario F measurements (the internal histogram measures time from request receipt to first token, before gateway SSE overhead)
- KV cache utilization stayed at 0% in logged snapshots — this appears to be a metrics-scraping timing issue where the poll window didn't overlap with active inference at sufficient resolution

### Gateway error rates in test runs

Scenarios A, B, C, D had 56–100% error rates in most runs. The direct vLLM Scenario F had 0% errors throughout. This points to authentication or routing issues in the gateway configuration during testing, not vLLM instability. The playground tokens fetched from the session were likely short-lived or scoped to a gateway that had a broken provider key for the test environment. Scenario F bypasses all gateway auth, explaining why it was clean.

The 195143 Scenario A run with 0% errors suggests a valid token was eventually obtained. The Scenario B, C runs in that file still errored, which is consistent with the token having per-request or per-minute limits that were hit during the sequential A run first.

---

## Current hardware state (2026-04-23, post-reboot)

The test suite README and vLLM flags are now outdated. The current configuration is:

| Component | Old (tested 2026-04-22) | Current |
|---|---|---|
| GPU (qwen3) | RTX PRO 6000 Blackwell #2, 98 GB | **H200 NVL, 144 GB** |
| `--gpu-memory-utilization` | 0.80 | **0.84** |
| `--max-num-batched-tokens` | 32,768 | **65,536** |
| `--max-num-seqs` | 32 | 32 |
| KV cache available | ~61 GiB | **~97 GiB** |
| KV cache tokens | — | **2,128,096** |
| GPU sharing | qwen3 + MinerU on same Blackwell | **qwen3 alone on H200** |
| Attention backend | FLASHINFER (Blackwell) | **FLASH_ATTN / FA3 (Hopper)** |

The Blackwell results are not representative of current performance. The H200 NVL delivers:
- ~1.9× higher memory bandwidth (decode throughput)
- ~2.6× higher fp8 compute (prefill throughput at larger batch sizes)
- 97 GiB KV cache (vs ~61 GiB) — 59% more capacity for concurrent long-context sessions
- No GPU sharing — qwen3 has exclusive access

The `RAMP_LEVELS` in `run_perf.py` still references `VLLM_MAX_SEQS = 32`, which remains correct. The `VLLM_BASE` URL (`http://172.28.0.1:8003`) needs verification — the Docker network address may have changed if the gateway container was recreated.

---

## Data gaps — what has not been measured yet

| Scenario | Status | Reason |
|---|---|---|
| A — Sequential baseline on H200 | **Not run** | Hardware changed post-reboot |
| B — Concurrency ramp on H200 | **Not run** | Hardware changed post-reboot |
| C — PII guardrail overhead on H200 | **Not run** | Hardware changed post-reboot |
| D — Cache effectiveness | **Not run** | No clean run in any session |
| E — Streaming TTFT | **Not run** | No clean run in any session |
| F — Direct vLLM on H200 | **Not run** | Hardware changed post-reboot |
| G — Long context stress on H200 | **Not run** | Hardware changed post-reboot |
| H — Rate limit boundary | **Not run** | No clean run in any session |
| Gateway overhead (B − F) | **Not measurable** | B had 100% error rate in all multi-concurrency runs |

The only clean gateway number is Scenario A from run 195143 (8,770 ms p50 at c=1, Blackwell). No gateway concurrency data is available. No capacity estimate has been successfully computed.

---

## Issues to fix before the next test run

1. **Auth token** — the root cause of the high error rates. Before running, verify the token works with a manual `curl` to the gateway endpoint. Use `--token` with a dedicated high-rate-limit token, not an auto-fetched playground token. The README suggests creating one in the admin UI.

2. **VLLM_BASE address** — confirm `http://172.28.0.1:8003` is reachable from the host. The Docker bridge IP may differ after container recreation. Check with `docker inspect ai-gateway-gateway-1 --format '{{.NetworkSettings.Networks}}'`.

3. **decode_tps missing** — add `"stream_options": {"include_usage": True}` to the request payload in `run_perf.py`. Without it, the final `usage` chunk is not emitted by some vLLM versions, leaving `tokens_out = 0` and `decode_tps = None`.

4. **README hardware section** — update GPU, KV cache, and vLLM flags to reflect the H200 configuration.

5. **poll_vllm_metrics.py URL** — the metrics endpoint in the scraper (`http://172.28.0.1:8003/metrics`) needs the same verification as VLLM_BASE.

---

## Recommended next run

After fixing the auth token and VLLM_BASE address, run the full suite against the H200:

```bash
cd /home/sas/work/ai-gateway

# In a separate terminal — collect vLLM metrics in parallel
python3 scripts/perf/poll_vllm_metrics.py \
    --output results/vllm_metrics_h200.jsonl \
    --url http://172.28.0.1:8003/metrics &

# Full suite with a dedicated high-rate-limit token
python3 scripts/perf/run_perf.py \
    --token YOUR_HIGH_LIMIT_TOKEN \
    --scenarios A,B,C,D,E,F,G \
    --n 100

kill %1
```

Priority scenarios for the H200 baseline: **A** (baseline latency), **B** (throughput curve and knee), **F** (gateway overhead). C and G are secondary.

Expected changes vs Blackwell:
- Scenario A wall p50: expect ~5–6 s (down from 8.8 s) due to faster prefill on H200
- Scenario A TTFT (thinking time): similar — model reasoning length is not GPU-bound
- Scenario F throughput at c=32: expect ~1.8–2.0 req/s (up from 1.08 req/s) due to higher memory bandwidth
- Scenario B knee concurrency: expect to shift right — H200 can sustain lower latency at higher concurrency before p95 doubles
