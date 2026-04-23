#!/usr/bin/env python3
"""
run_perf.py — AI Gateway performance test suite.

Measures latency and throughput for qwen3-30b-a3b (local vLLM) and
the PII guardrail overhead, to estimate max concurrent user capacity.

Usage:
  python3 run_perf.py [--token TOKEN] [--scenarios A,B,C] [--n 100]
  python3 run_perf.py --scenarios A --n 10 --no-warmup   # quick smoke test

Requirements:
  pip install httpx    (standard: pip3 install httpx)
  Python 3.10+

Before running:
  1. Create a dedicated test gateway token (high rate-limit) in the admin UI
     or pass --token to use a playground token auto-fetched from the session.
  2. Ensure scripts/perf/prompts.jsonl exists (run gen_prompts.py first).
  3. Optionally start poll_vllm_metrics.py in a separate terminal.
"""

import argparse
import asyncio
import json
import os
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass, asdict, field
from datetime import datetime
from typing import Optional

try:
    import httpx
except ImportError:
    sys.exit("ERROR: httpx not installed. Run: pip3 install httpx")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REPO_ROOT      = pathlib.Path(__file__).parent.parent.parent
SESSION_FILE   = REPO_ROOT / "frontend/tests/.auth/docker-session.json"
PROMPTS_FILE   = pathlib.Path(__file__).parent / "prompts.jsonl"
RESULTS_DIR    = REPO_ROOT / "results"

ADMIN_BASE     = "https://ai-api-admin.myra.eu"
GATEWAY_BASE   = "https://ai-api.myra.eu"
VLLM_BASE      = "http://172.28.0.1:8003"
TENANT         = "myratest"
GATEWAY_PROD   = "prod"
GATEWAY_PII    = "prod-pii"
MODEL          = "qwen3-30b-a3b"

# vLLM hard limit: --max-num-seqs 32
VLLM_MAX_SEQS  = 32

WARMUP_N       = 10
WARMUP_CONCUR  = 4
DEFAULT_N      = 100
DEFAULT_SCENARIOS = "A,B,C,D,E,F,G"

# Scenario B ramp — stops automatically if p95 > 15s or errors > 2%
RAMP_LEVELS = [1, 2, 4, 8, 12, 16, 24, 32, 48, 64]
RAMP_P95_LIMIT_MS  = 15_000
RAMP_ERROR_LIMIT   = 0.02

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class Measurement:
    scenario:    str
    concurrency: int
    prompt_idx:  int
    start_time:  float
    end_time:    float
    wall_ms:     float
    ttft_ms:     Optional[float]   # first non-empty delta.content
    decode_ms:   Optional[float]
    prefill_tps: Optional[float]   # tokens_in / (ttft_ms/1000)
    decode_tps:  Optional[float]   # tokens_out / (decode_ms/1000)
    status:      int
    tokens_in:   int
    tokens_out:  int
    cached:      bool
    error_type:  Optional[str]
    endpoint:    str               # "gateway" or "vllm_direct"

# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def load_session_cookies() -> dict:
    """Load cookies from Playwright auth session file."""
    try:
        data = json.loads(SESSION_FILE.read_text())
        return {c["name"]: c["value"] for c in data.get("cookies", [])}
    except Exception as e:
        print(f"WARN: could not load session cookies from {SESSION_FILE}: {e}")
        return {}


def fetch_tenant_id(cookies: dict) -> Optional[str]:
    resp = httpx.get(f"{ADMIN_BASE}/admin/v1/tenants",
                     headers={"Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())},
                     timeout=10)
    if not resp.is_success:
        return None
    for t in resp.json():
        if t.get("slug") == TENANT:
            return t["id"]
    return None


def fetch_gateway_id(cookies: dict, tenant_id: str, slug: str) -> Optional[str]:
    resp = httpx.get(f"{ADMIN_BASE}/admin/v1/tenants/{tenant_id}/gateways",
                     headers={"Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())},
                     timeout=10)
    if not resp.is_success:
        return None
    for g in resp.json():
        if g.get("slug") == slug:
            return g["id"]
    return None


def fetch_playground_token(cookies: dict, gateway_id: str) -> Optional[str]:
    resp = httpx.post(f"{ADMIN_BASE}/admin/v1/playground/token",
                      json={"gateway_id": gateway_id, "model": MODEL},
                      headers={"Cookie": "; ".join(f"{k}={v}" for k, v in cookies.items())},
                      timeout=10)
    if not resp.is_success:
        return None
    data = resp.json()
    return data.get("token")

# ---------------------------------------------------------------------------
# Prompt loading
# ---------------------------------------------------------------------------

def load_prompts() -> list[dict]:
    if not PROMPTS_FILE.exists():
        print(f"WARN: {PROMPTS_FILE} not found, using fallback prompts")
        return _fallback_prompts()
    prompts = [json.loads(l) for l in PROMPTS_FILE.read_text().splitlines() if l.strip()]
    if not prompts:
        return _fallback_prompts()
    return prompts


def _fallback_prompts() -> list[dict]:
    texts = [
        "Explain what a circuit breaker pattern is in software architecture.",
        "Compare REST and GraphQL APIs. List pros and cons of each approach.",
        "Write a Python function to retry HTTP requests with exponential backoff and jitter.",
        "Describe the key differences between TCP and UDP, with use cases for each.",
        "What is eventual consistency in distributed systems and how do you handle it?",
    ]
    return [{"text": t, "approx_tokens": len(t.split()) * 1.3} for t in texts]

# ---------------------------------------------------------------------------
# Core request function
# ---------------------------------------------------------------------------

async def make_request(
    client: httpx.AsyncClient,
    url: str,
    payload: dict,
    token: str,
    scenario: str,
    concurrency: int,
    prompt_idx: int,
    endpoint: str = "gateway",
) -> Measurement:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["x-aig-token"] = token

    t0 = time.perf_counter()
    start_ts = time.time()
    ttft_ms = None
    tokens_in = 0
    tokens_out = 0
    cached = False
    error_type = None
    status = 0

    try:
        async with client.stream("POST", url, json=payload, headers=headers) as resp:
            status = resp.status_code
            cached = resp.headers.get("x-aig-cache", "").upper() == "HIT"

            if not resp.is_success:
                body = await resp.aread()
                error_type = f"http_{status}"
            else:
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    payload_str = line[6:].strip()
                    if payload_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload_str)
                        # TTFT: first chunk with non-empty delta.content
                        # Use `or ""` to handle content=null (JSON null → Python None)
                        if ttft_ms is None:
                            content = (chunk.get("choices", [{}])[0]
                                           .get("delta", {})
                                           .get("content") or "")
                            if content:
                                ttft_ms = (time.perf_counter() - t0) * 1000

                        # Token counts from usage chunk
                        usage = chunk.get("usage")
                        if usage:
                            tokens_in  = usage.get("prompt_tokens", tokens_in)
                            tokens_out = usage.get("completion_tokens", tokens_out)

                        # Custom status events (tool loop) — ignore for timing
                    except json.JSONDecodeError:
                        pass

    except httpx.TimeoutException:
        error_type = "timeout"
        status = 0
    except Exception as e:
        error_type = f"exception:{type(e).__name__}"
        status = 0

    end_ts = time.time()
    wall_ms = (time.perf_counter() - t0) * 1000

    approx_tokens_in = payload.get("messages", [{}])[-1].get("_approx_tokens", tokens_in)
    if tokens_in == 0:
        tokens_in = approx_tokens_in

    decode_ms  = (wall_ms - ttft_ms) if ttft_ms is not None else None
    prefill_tps = (tokens_in / (ttft_ms / 1000)) if ttft_ms and ttft_ms > 0 and tokens_in > 0 else None
    decode_tps  = (tokens_out / (decode_ms / 1000)) if decode_ms and decode_ms > 0 and tokens_out > 0 else None

    return Measurement(
        scenario=scenario,
        concurrency=concurrency,
        prompt_idx=prompt_idx,
        start_time=start_ts,
        end_time=end_ts,
        wall_ms=wall_ms,
        ttft_ms=ttft_ms,
        decode_ms=decode_ms,
        prefill_tps=prefill_tps,
        decode_tps=decode_tps,
        status=status,
        tokens_in=tokens_in,
        tokens_out=tokens_out,
        cached=cached,
        error_type=error_type,
        endpoint=endpoint,
    )

# ---------------------------------------------------------------------------
# Scenario runner
# ---------------------------------------------------------------------------

async def run_batch(
    client: httpx.AsyncClient,
    url: str,
    prompts: list[dict],
    token: str,
    scenario: str,
    concurrency: int,
    n: int,
    endpoint: str = "gateway",
    show_progress: bool = True,
) -> list[Measurement]:
    sem = asyncio.Semaphore(concurrency)
    results = []
    import itertools
    prompt_cycle = list(itertools.islice(itertools.cycle(prompts), n))
    completed = 0

    async def bounded(idx: int, prompt: dict) -> Measurement:
        async with sem:
            payload = {
                "model": MODEL,
                "messages": [{"role": "user", "content": prompt["text"],
                               "_approx_tokens": prompt.get("approx_tokens", 500)}],
                # 2048: verified that 1024 causes some prompts to consume all tokens in
                # <think> blocks (content_chars=0 in gateway log), leaving no budget for
                # visible output. 2048 gives enough room to finish reasoning + answer.
                "max_tokens": 2048,
                "stream": True,
                "stream_options": {"include_usage": True},
                "temperature": 0.7,
            }
            # Strip private field before sending
            payload["messages"][0].pop("_approx_tokens", None)

            m = await make_request(client, url, payload, token, scenario, concurrency, idx, endpoint)
            nonlocal completed
            completed += 1
            if show_progress:
                sym = "✓" if m.error_type is None and m.status == 200 else "✗"
                print(f"  [{completed:3d}/{n}] {sym} {m.wall_ms:6.0f}ms  "
                      f"ttft={m.ttft_ms or 0:5.0f}ms  "
                      f"tok={m.tokens_out:3d}  "
                      f"{'CACHED' if m.cached else ''}  "
                      f"{m.error_type or ''}",
                      flush=True)
            return m

    tasks = [bounded(i, p) for i, p in enumerate(prompt_cycle)]
    results = await asyncio.gather(*tasks, return_exceptions=False)
    return list(results)

# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = (len(s) - 1) * p / 100
    lo, hi = int(idx), min(int(idx) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)


def stats(measurements: list[Measurement], key: str) -> dict:
    vals = [getattr(m, key) for m in measurements
            if getattr(m, key) is not None and m.error_type is None and m.status == 200]
    if not vals:
        return {"p50": 0, "p90": 0, "p95": 0, "p99": 0, "max": 0, "mean": 0, "n": 0}
    return {
        "p50":  round(percentile(vals, 50), 1),
        "p90":  round(percentile(vals, 90), 1),
        "p95":  round(percentile(vals, 95), 1),
        "p99":  round(percentile(vals, 99), 1),
        "max":  round(max(vals), 1),
        "mean": round(sum(vals) / len(vals), 1),
        "n":    len(vals),
    }


def throughput(measurements: list[Measurement]) -> float:
    good = [m for m in measurements if m.error_type is None and m.status == 200]
    if len(good) < 2:
        return 0.0
    elapsed = max(m.end_time for m in good) - min(m.start_time for m in good)
    return len(good) / elapsed if elapsed > 0 else 0.0


def error_rate(measurements: list[Measurement]) -> float:
    if not measurements:
        return 0.0
    errors = sum(1 for m in measurements if m.error_type or m.status not in (200, 201))
    return errors / len(measurements)

# ---------------------------------------------------------------------------
# Warm-up
# ---------------------------------------------------------------------------

async def run_warmup(client: httpx.AsyncClient, url: str, prompts: list, token: str):
    print(f"\n{'='*60}")
    print(f"Warm-up: {WARMUP_N} requests at concurrency={WARMUP_CONCUR} (not recorded)")
    print(f"{'='*60}")
    await run_batch(client, url, prompts, token, "warmup", WARMUP_CONCUR, WARMUP_N,
                    show_progress=False)
    print(f"  Warm-up complete. Waiting 10 s…")
    await asyncio.sleep(10)

# ---------------------------------------------------------------------------
# Individual scenarios
# ---------------------------------------------------------------------------

async def scenario_A(client, url, prompts, token, n, results_all):
    print(f"\n{'='*60}")
    print(f"Scenario A — Sequential baseline (concurrency=1, n={n})")
    print(f"{'='*60}")
    ms = await run_batch(client, url, prompts, token, "A", 1, n)
    results_all["A"] = {"1": ms}
    wall = stats(ms, "wall_ms")
    ttft = stats(ms, "ttft_ms")
    print(f"\n  wall: p50={wall['p50']:.0f}ms  p95={wall['p95']:.0f}ms  p99={wall['p99']:.0f}ms  max={wall['max']:.0f}ms")
    print(f"  ttft: p50={ttft['p50']:.0f}ms  p95={ttft['p95']:.0f}ms")
    print(f"  tput: {throughput(ms):.3f} req/s   errors: {error_rate(ms)*100:.1f}%")
    return wall


async def scenario_B(client, url, prompts, token, n, results_all, p95_baseline_ms):
    print(f"\n{'='*60}")
    print(f"Scenario B — Concurrency ramp (n={n} per level)")
    print(f"{'='*60}")
    results_all["B"] = {}
    knee = None

    print(f"  {'c':>4}  {'p50':>7}  {'p95':>7}  {'p99':>7}  {'max':>7}  {'tput':>8}  {'err%':>5}  {'note'}")
    print(f"  {'-'*4}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*7}  {'-'*8}  {'-'*5}  {'-'*15}")

    for c in RAMP_LEVELS:
        if c > VLLM_MAX_SEQS:
            print(f"  {c:4d}  [skipping — exceeds vLLM --max-num-seqs={VLLM_MAX_SEQS}]")
            break

        ms = await run_batch(client, url, prompts, token, "B", c, n, show_progress=False)
        results_all["B"][str(c)] = ms
        w = stats(ms, "wall_ms")
        er = error_rate(ms)
        tput = throughput(ms)

        note = ""
        if w["p95"] > RAMP_P95_LIMIT_MS:
            note = "⚠ p95>15s — STOP"
        elif er > RAMP_ERROR_LIMIT:
            note = "⚠ errors>2% — STOP"
        elif p95_baseline_ms and w["p95"] > 2 * p95_baseline_ms and knee is None:
            note = "← knee"
            knee = c

        print(f"  {c:4d}  {w['p50']:>7.0f}  {w['p95']:>7.0f}  {w['p99']:>7.0f}  "
              f"{w['max']:>7.0f}  {tput:>7.3f}/s  {er*100:>5.1f}%  {note}")

        if note.startswith("⚠"):
            break

    return knee


async def scenario_C(client, url_prod, url_pii, prompts, token_prod, token_pii, n, results_all):
    CONCUR = 8
    print(f"\n{'='*60}")
    print(f"Scenario C — Guardrail A/B (concurrency={CONCUR}, n={n})")
    print(f"{'='*60}")

    # Use same prompts (subset of medium-token ones to ensure PII check is non-trivial)
    batch_prompts = [p for p in prompts if 1500 <= p.get("approx_tokens", 0) <= 2500][:n] or prompts[:n]

    print(f"  Running on prod (no guardrail)…")
    ms_prod = await run_batch(client, url_prod, batch_prompts, token_prod, "C_prod", CONCUR, n, show_progress=False)
    print(f"  Running on prod-pii (PII guardrail)…")
    ms_pii  = await run_batch(client, url_pii,  batch_prompts, token_pii,  "C_pii",  CONCUR, n, show_progress=False)

    results_all["C"] = {"prod": ms_prod, "pii": ms_pii}

    wp = stats(ms_prod, "wall_ms")
    wi = stats(ms_pii,  "wall_ms")
    overhead = wi["p50"] - wp["p50"]

    print(f"\n  {'':20}  {'p50':>7}  {'p95':>7}  {'p99':>7}  {'tput':>8}")
    print(f"  {'prod (no guardrail)':20}  {wp['p50']:>7.0f}  {wp['p95']:>7.0f}  {wp['p99']:>7.0f}  {throughput(ms_prod):>7.3f}/s")
    print(f"  {'prod-pii (PII guard)':20}  {wi['p50']:>7.0f}  {wi['p95']:>7.0f}  {wi['p99']:>7.0f}  {throughput(ms_pii):>7.3f}/s")
    print(f"  PII overhead: +{overhead:.0f} ms at p50")


async def scenario_D(client, url, prompts, token, n, results_all):
    """Cache effectiveness: 50 unique + 50 exact repeats."""
    CONCUR = 8
    print(f"\n{'='*60}")
    print(f"Scenario D — Cache effectiveness (concurrency={CONCUR}, n={n})")
    print(f"{'='*60}")
    half = n // 2
    unique_prompts = prompts[:half]
    repeat_prompts = prompts[:half]  # same prompts = cache hits after first run

    # First run: unique (populate cache)
    ms_unique = await run_batch(client, url, unique_prompts, token, "D_unique", CONCUR, half, show_progress=False)
    # Second run: same prompts (should get cache hits if TTL not expired)
    ms_repeat = await run_batch(client, url, repeat_prompts, token, "D_repeat", CONCUR, half, show_progress=False)

    results_all["D"] = {"unique": ms_unique, "repeat": ms_repeat}

    wu = stats(ms_unique, "wall_ms")
    wr = stats(ms_repeat, "wall_ms")
    hit_rate = sum(1 for m in ms_repeat if m.cached) / len(ms_repeat) * 100 if ms_repeat else 0

    print(f"\n  {'unique (miss)':20}  p50={wu['p50']:.0f}ms  p95={wu['p95']:.0f}ms")
    print(f"  {'repeat (cache)':20}  p50={wr['p50']:.0f}ms  p95={wr['p95']:.0f}ms   hit_rate={hit_rate:.1f}%")
    latency_saving = wu["p50"] - wr["p50"]
    print(f"  Cache saves ~{latency_saving:.0f} ms per hit at p50")


async def scenario_E(client, url, prompts, token, n, results_all):
    print(f"\n{'='*60}")
    print(f"Scenario E — Streaming TTFT at concurrency levels (n={n})")
    print(f"{'='*60}")
    results_all["E"] = {}

    print(f"  {'c':>4}  {'wall_p50':>9}  {'ttft_p50':>9}  {'ttft_p95':>9}  {'decode_tps_p50':>14}")
    for c in [1, 4, 8, 16]:
        if c > VLLM_MAX_SEQS:
            break
        ms = await run_batch(client, url, prompts, token, "E", c, n, show_progress=False)
        results_all["E"][str(c)] = ms
        w = stats(ms, "wall_ms")
        t = stats(ms, "ttft_ms")
        d = stats(ms, "decode_tps")
        print(f"  {c:4d}  {w['p50']:>9.0f}  {t['p50']:>9.0f}  {t['p95']:>9.0f}  {d['p50']:>14.1f}")


async def scenario_F(client_direct, url_direct, prompts, token_direct, n, results_all,
                     results_B: dict):
    """Direct vLLM baseline — gateway overhead = B_ms - F_ms."""
    print(f"\n{'='*60}")
    print(f"Scenario F — Direct vLLM baseline (bypass gateway, n={n})")
    print(f"{'='*60}")
    results_all["F"] = {}

    print(f"  {'c':>4}  {'vllm_p50':>9}  {'vllm_p95':>9}  {'tput':>8}  {'overhead_p50':>12}")
    for c in [1, 2, 4, 8, 16, 32]:
        if c > VLLM_MAX_SEQS:
            break
        ms = await run_batch(client_direct, url_direct, prompts, "", "F", c, n,
                             endpoint="vllm_direct", show_progress=False)
        results_all["F"][str(c)] = ms
        w = stats(ms, "wall_ms")
        tput = throughput(ms)

        # Compare with gateway ramp (Scenario B) at same concurrency
        overhead_str = ""
        if str(c) in results_B:
            gw_p50 = stats(results_B[str(c)], "wall_ms")["p50"]
            overhead = gw_p50 - w["p50"]
            overhead_str = f"+{overhead:.0f} ms"

        print(f"  {c:4d}  {w['p50']:>9.0f}  {w['p95']:>9.0f}  {tput:>7.3f}/s  {overhead_str:>12}")


async def scenario_G(client, url, prompts, token, results_all):
    """Long context stress: 8000-token inputs."""
    CONCUR = 4
    N = 50
    print(f"\n{'='*60}")
    print(f"Scenario G — Long context stress (concurrency={CONCUR}, n={N}, ~8k tokens)")
    print(f"{'='*60}")

    long_prompts = [p for p in prompts if p.get("approx_tokens", 0) >= 5000]
    if len(long_prompts) < N:
        # Pad by repeating
        import itertools
        long_prompts = list(itertools.islice(itertools.cycle(long_prompts), N)) if long_prompts else prompts[:N]

    ms = await run_batch(client, url, long_prompts, token, "G", CONCUR, N, show_progress=False)
    results_all["G"] = {"4": ms}

    w = stats(ms, "wall_ms")
    t = stats(ms, "ttft_ms")
    print(f"  wall: p50={w['p50']:.0f}ms  p95={w['p95']:.0f}ms  max={w['max']:.0f}ms")
    print(f"  ttft: p50={t['p50']:.0f}ms  p95={t['p95']:.0f}ms  (expect high due to prefill)")
    print(f"  errors: {error_rate(ms)*100:.1f}%")


async def scenario_H(client, url, prompts, token, results_all):
    """Rate limit boundary — ramp until 429 appears."""
    print(f"\n{'='*60}")
    print(f"Scenario H — Rate limit boundary")
    print(f"{'='*60}")
    results_all["H"] = {}

    for c in [4, 8, 16, 32, 48]:
        ms = await run_batch(client, url, prompts, token, "H", c, 20, show_progress=False)
        results_all["H"][str(c)] = ms
        n429 = sum(1 for m in ms if m.status == 429)
        tput = throughput(ms)
        print(f"  c={c:2d}  tput={tput:.2f}/s ({tput*60:.0f}/min)  429s={n429}/{len(ms)}")
        if n429 > 0:
            print(f"  Rate limit triggered at concurrency={c} (~{tput*60:.0f} req/min)")
            break

# ---------------------------------------------------------------------------
# Capacity estimation
# ---------------------------------------------------------------------------

def estimate_capacity(results_all: dict) -> dict:
    """Apply Little's Law and find the 'knee' concurrency."""
    B = results_all.get("B", {})
    if not B:
        return {}

    # p95_baseline from concurrency=1
    ms1 = B.get("1", [])
    if not ms1:
        return {}
    p95_baseline = stats(ms1, "wall_ms")["p95"]

    knee_c = None
    hard_ceiling_c = None
    table = []

    for c_str, ms in sorted(B.items(), key=lambda x: int(x[0])):
        c = int(c_str)
        w = stats(ms, "wall_ms")
        er = error_rate(ms)
        tput = throughput(ms)
        # Little's Law: L = lambda * W  →  lambda_max = L / W_mean
        W_mean = w["mean"] / 1000  # seconds
        lambda_hat = c / W_mean if W_mean > 0 else 0

        if w["p95"] <= 2 * p95_baseline and knee_c is None:
            knee_c = c
        if er < 0.02 and w["p95"] < 15000:
            hard_ceiling_c = c

        table.append({
            "concurrency": c,
            "p50_ms": w["p50"],
            "p95_ms": w["p95"],
            "throughput_rps": round(tput, 3),
            "throughput_rpm": round(tput * 60, 1),
            "error_rate_pct": round(er * 100, 1),
            "littles_lambda_rps": round(lambda_hat, 3),
        })

    # Comfortable capacity = last level where p95 < 10 s
    comfortable_c = None
    for row in table:
        if row["p95_ms"] < 10_000:
            comfortable_c = row["concurrency"]

    return {
        "ramp_table": table,
        "knee_concurrency": knee_c,
        "comfortable_concurrency": comfortable_c,
        "hard_ceiling_concurrency": hard_ceiling_c,
        "p95_baseline_ms": round(p95_baseline, 0),
        "note": "max_concurrent_requests != max_users (think time not measured)",
    }

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------

def write_report(results_all: dict, capacity: dict, out_path: pathlib.Path,
                 vllm_flags: str, gpu_info: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        f"# AI Gateway Performance Report",
        f"",
        f"Generated: {ts}",
        f"",
        f"## System configuration",
        f"",
        f"| Item | Value |",
        f"|---|---|",
        f"| Model | qwen3-30b-a3b (MoE, 3B active / 30B total, AWQ quantized) |",
        f"| GPU | {gpu_info} |",
        f"| vLLM flags | `{vllm_flags}` |",
        f"| Gateway | OpenResty/Lua, prod gateway (no guardrail), prod-pii (PII guardrail) |",
        f"",
        f"## Capacity summary",
        f"",
    ]

    if capacity:
        lines += [
            f"| Metric | Value |",
            f"|---|---|",
            f"| p95 latency at concurrency=1 | {capacity.get('p95_baseline_ms', '?')} ms |",
            f"| Comfortable capacity (p95 < 10 s) | **{capacity.get('comfortable_concurrency', '?')} concurrent requests** |",
            f"| Hard ceiling (errors < 2%) | {capacity.get('hard_ceiling_concurrency', '?')} concurrent requests |",
            f"",
            f"> ⚠ **Note:** This is max concurrent *requests*, not max concurrent *users*.",
            f"> Users have think time; max users = max\\_concurrent\\_requests × (1 + think\\_time / mean\\_latency).",
            f"",
        ]

        if capacity.get("ramp_table"):
            lines += [
                f"## Scenario B — Concurrency ramp",
                f"",
                f"| c | p50 (ms) | p95 (ms) | tput (req/s) | tput (req/min) | errors% |",
                f"|---|---|---|---|---|---|",
            ]
            for row in capacity["ramp_table"]:
                lines.append(
                    f"| {row['concurrency']} | {row['p50_ms']:.0f} | {row['p95_ms']:.0f} | "
                    f"{row['throughput_rps']:.3f} | {row['throughput_rpm']:.1f} | "
                    f"{row['error_rate_pct']:.1f}% |"
                )
            lines.append("")

    # Scenario C — guardrail overhead
    if "C" in results_all:
        prod_ms = stats(results_all["C"].get("prod", []), "wall_ms")
        pii_ms  = stats(results_all["C"].get("pii",  []), "wall_ms")
        overhead = pii_ms["p50"] - prod_ms["p50"] if prod_ms["p50"] and pii_ms["p50"] else 0
        lines += [
            f"## Scenario C — PII guardrail overhead (concurrency=8)",
            f"",
            f"| Gateway | p50 (ms) | p95 (ms) | tput (req/s) |",
            f"|---|---|---|---|",
            f"| prod (no guardrail) | {prod_ms['p50']:.0f} | {prod_ms['p95']:.0f} | "
            f"{throughput(results_all['C']['prod']):.3f} |",
            f"| prod-pii (PII guard) | {pii_ms['p50']:.0f} | {pii_ms['p95']:.0f} | "
            f"{throughput(results_all['C']['pii']):.3f} |",
            f"| **PII overhead** | **+{overhead:.0f} ms** at p50 | | |",
            f"",
        ]

    # Scenario F — gateway overhead
    if "F" in results_all and "B" in results_all:
        lines += [
            f"## Scenario F — Gateway overhead (gateway vs direct vLLM)",
            f"",
            f"| c | vLLM direct p50 (ms) | gateway p50 (ms) | overhead (ms) |",
            f"|---|---|---|---|",
        ]
        for c_str, ms_vllm in sorted(results_all["F"].items(), key=lambda x: int(x[0])):
            c = int(c_str)
            vllm_p50 = stats(ms_vllm, "wall_ms")["p50"]
            gw_p50 = stats(results_all["B"].get(c_str, []), "wall_ms").get("p50", 0)
            overhead = gw_p50 - vllm_p50 if gw_p50 else 0
            lines.append(f"| {c} | {vllm_p50:.0f} | {gw_p50:.0f} | +{overhead:.0f} |")
        lines.append("")

    lines += [
        f"## Assumptions",
        f"",
        f"1. Synthetic prompts approximate 7-day production median (1,935 input, 463 output tokens)",
        f"2. vLLM `--max-num-seqs 32` is the hardware ceiling for in-flight requests",
        f"3. Rate limiting is per-nginx-worker shared dict (not globally enforced across workers)",
        f"4. \"Comfortable capacity\" = highest concurrency where p95 < 10 s (interactive SLO)",
        f"5. \"Max users\" requires think-time data not collected in this test",
        f"",
    ]

    out_path.write_text("\n".join(lines))
    print(f"\nReport written to {out_path}")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def get_vllm_info() -> tuple[str, str]:
    try:
        ps = subprocess.run(["ps", "aux"], capture_output=True, text=True)
        for line in ps.stdout.splitlines():
            if "qwen3-30b-a3b" in line and "vllm" in line:
                flags = []
                for flag in ["--max-num-seqs", "--max-num-batched-tokens",
                              "--gpu-memory-utilization", "--enable-chunked-prefill",
                              "--enable-prefix-caching", "--kv-cache-dtype"]:
                    if flag in line:
                        idx = line.index(flag)
                        token = line[idx:].split()[0:2]
                        flags.append(" ".join(token))
                return " ".join(flags), line[:40]
    except Exception:
        pass
    return "unknown", "unknown"


def get_gpu_info() -> str:
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used",
             "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5)
        lines = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        return " | ".join(lines)
    except Exception:
        return "unknown"


async def main():
    parser = argparse.ArgumentParser(description="AI Gateway performance test suite")
    parser.add_argument("--token",    help="Gateway token (auto-fetched from session if omitted)")
    parser.add_argument("--scenarios", default=DEFAULT_SCENARIOS,
                        help=f"Comma-separated scenarios to run (default: {DEFAULT_SCENARIOS})")
    parser.add_argument("--n", type=int, default=DEFAULT_N,
                        help=f"Requests per concurrency level (default: {DEFAULT_N})")
    parser.add_argument("--no-warmup", action="store_true", help="Skip warm-up phase")
    parser.add_argument("--output-dir", default=str(RESULTS_DIR))
    args = parser.parse_args()

    scenarios = {s.strip().upper() for s in args.scenarios.split(",")}
    n = args.n

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    ts_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_file = RESULTS_DIR / f"perf_{ts_str}.jsonl"
    report_file  = RESULTS_DIR / f"report_{ts_str}.md"

    # ---------- auth / token setup ----------
    cookies = load_session_cookies()
    token_prod = args.token
    token_pii  = args.token

    if not token_prod:
        print("Fetching playground tokens from session…")
        tenant_id = fetch_tenant_id(cookies)
        if not tenant_id:
            sys.exit("ERROR: could not fetch tenant ID. Pass --token explicitly.")
        gw_prod_id = fetch_gateway_id(cookies, tenant_id, GATEWAY_PROD)
        gw_pii_id  = fetch_gateway_id(cookies, tenant_id, GATEWAY_PII)
        token_prod = fetch_playground_token(cookies, gw_prod_id) if gw_prod_id else None
        token_pii  = fetch_playground_token(cookies, gw_pii_id)  if gw_pii_id  else None
        if not token_prod:
            sys.exit("ERROR: could not fetch playground token. Pass --token explicitly.")
        print(f"  prod token: {token_prod[:12]}…")
        if token_pii:
            print(f"  pii  token: {token_pii[:12]}…")

    # ---------- URLs ----------
    url_prod   = f"{GATEWAY_BASE}/v1/{TENANT}/{GATEWAY_PROD}/compat/chat/completions"
    url_pii    = f"{GATEWAY_BASE}/v1/{TENANT}/{GATEWAY_PII}/compat/chat/completions"
    url_direct = f"{VLLM_BASE}/v1/chat/completions"

    vllm_flags, _ = get_vllm_info()
    gpu_info = get_gpu_info()

    print(f"\nAI Gateway Performance Suite")
    print(f"  Scenarios : {sorted(scenarios)}")
    print(f"  n/level   : {n}")
    print(f"  Endpoint  : {url_prod}")
    print(f"  vLLM flags: {vllm_flags}")
    print(f"  GPU       : {gpu_info}")
    print(f"  Results   : {results_file}")

    prompts = load_prompts()
    print(f"  Prompts   : {len(prompts)} loaded from {PROMPTS_FILE}")

    results_all = {}

    # ---------- shared client ----------
    limits = httpx.Limits(max_connections=200, max_keepalive_connections=100)
    timeout = httpx.Timeout(connect=10.0, read=180.0, write=15.0, pool=10.0)

    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        # Direct vLLM client (no TLS)
        limits_direct = httpx.Limits(max_connections=100, max_keepalive_connections=50)
        async with httpx.AsyncClient(limits=limits_direct, timeout=timeout) as client_direct:

            # Warm-up
            if not args.no_warmup:
                await run_warmup(client, url_prod, prompts, token_prod)

            p95_baseline_ms = None

            if "A" in scenarios:
                w = await scenario_A(client, url_prod, prompts, token_prod, n, results_all)
                p95_baseline_ms = w.get("p95")

            if "B" in scenarios:
                knee = await scenario_B(client, url_prod, prompts, token_prod, n,
                                        results_all, p95_baseline_ms)
                if knee:
                    print(f"\n  → Knee concurrency: {knee} (p95 doubled)")

            if "C" in scenarios and token_pii:
                await scenario_C(client, url_prod, url_pii, prompts,
                                 token_prod, token_pii, n, results_all)
            elif "C" in scenarios:
                print("\nScenario C skipped (no prod-pii token)")

            if "D" in scenarios:
                await scenario_D(client, url_prod, prompts, token_prod, n, results_all)

            if "E" in scenarios:
                await scenario_E(client, url_prod, prompts, token_prod, n, results_all)

            if "F" in scenarios:
                await scenario_F(client_direct, url_direct, prompts, "",
                                 n, results_all, results_all.get("B", {}))

            if "G" in scenarios:
                await scenario_G(client, url_prod, prompts, token_prod, results_all)

            if "H" in scenarios:
                await scenario_H(client, url_prod, prompts, token_prod, results_all)

    # ---------- save raw results ----------
    with open(results_file, "w") as f:
        for scenario_key, data in results_all.items():
            if isinstance(data, dict):
                for level_key, ms in data.items():
                    for m in ms:
                        rec = asdict(m)
                        rec["scenario_key"] = scenario_key
                        rec["level_key"] = level_key
                        f.write(json.dumps(rec) + "\n")
    print(f"\nRaw results saved to {results_file}")

    # ---------- capacity estimate ----------
    capacity = estimate_capacity(results_all)
    if capacity:
        cc = capacity.get("comfortable_concurrency")
        hc = capacity.get("hard_ceiling_concurrency")
        print(f"\n{'='*60}")
        print(f"CAPACITY ESTIMATE")
        print(f"{'='*60}")
        print(f"  Comfortable capacity (p95 < 10 s): {cc} concurrent requests")
        print(f"  Hard ceiling (errors < 2%):         {hc} concurrent requests")
        print(f"  Note: concurrent requests ≠ concurrent users (think time unknown)")

    # ---------- write report ----------
    write_report(results_all, capacity, report_file, vllm_flags, gpu_info)

    print(f"\nDone. View report: cat {report_file}")


if __name__ == "__main__":
    asyncio.run(main())
