#!/usr/bin/env python3
"""
poll_vllm_metrics.py — Background vLLM Prometheus metrics poller.

Scrapes http://172.28.0.1:8003/metrics every 5 seconds and writes
timestamped JSONL to the specified output file.

Usage (background process during run_perf.py):
  python3 poll_vllm_metrics.py --output vllm_metrics_scenario_B.jsonl &
  # ... run tests ...
  kill %1

Fields captured:
  - gpu_cache_usage_perc   — KV cache utilisation (0–100)
  - num_requests_running   — requests currently in a batch
  - num_requests_waiting   — requests queued (not yet scheduled)
  - ttft_p50_s             — vLLM-internal TTFT p50 (seconds)
  - ttft_p95_s             — vLLM-internal TTFT p95 (seconds)
  - generation_tps         — total output tokens/sec since startup
  - prompt_tps             — total input tokens/sec since startup
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error

VLLM_METRICS_URL = "http://172.28.0.1:8003/metrics"
MODEL_NAME = "qwen3-30b-a3b"
POLL_INTERVAL = 5  # seconds


def parse_prometheus(text: str) -> dict:
    """Extract the metrics we care about from Prometheus text format."""
    result = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        # e.g. vllm:gpu_cache_usage_perc{engine="0",model_name="qwen3-30b-a3b"} 42.7
        if MODEL_NAME not in line and "qwen3" not in line:
            continue

        if "vllm:gpu_cache_usage_perc" in line:
            try:
                result["gpu_cache_usage_perc"] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

        elif "vllm:num_requests_running" in line:
            try:
                result["num_requests_running"] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

        elif "vllm:num_requests_waiting" in line:
            try:
                result["num_requests_waiting"] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

        elif 'vllm:generation_tokens_total' in line:
            try:
                result["generation_tokens_total"] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

        elif 'vllm:prompt_tokens_total' in line:
            try:
                result["prompt_tokens_total"] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass

    # Compute TTFT p50/p95 from histogram buckets
    result.update(_parse_histogram(text, "vllm:time_to_first_token_seconds"))
    result.update(_parse_histogram(text, "vllm:time_per_output_token_seconds", prefix="tpot"))

    return result


def _parse_histogram(text: str, metric_name: str, prefix: str = "ttft") -> dict:
    """Estimate p50 and p95 from a Prometheus histogram by linear interpolation."""
    buckets = []
    count = 0
    for line in text.splitlines():
        if metric_name + "_bucket" not in line:
            continue
        if MODEL_NAME not in line and "qwen3" not in line:
            continue
        # Extract le= and value
        try:
            import re
            le_match = re.search(r'le="([^"]+)"', line)
            if not le_match:
                continue
            le = le_match.group(1)
            value = float(line.split()[-1])
            if le == "+Inf":
                count = value
            else:
                buckets.append((float(le), value))
        except (ValueError, AttributeError):
            continue

    if not buckets or count == 0:
        return {}

    buckets.sort()

    def interp_percentile(p: float) -> float:
        target = p / 100 * count
        prev_le, prev_cnt = 0.0, 0.0
        for le, cnt in buckets:
            if cnt >= target:
                if cnt == prev_cnt:
                    return le
                frac = (target - prev_cnt) / (cnt - prev_cnt)
                return prev_le + frac * (le - prev_le)
            prev_le, prev_cnt = le, cnt
        return buckets[-1][0] if buckets else 0.0

    return {
        f"{prefix}_p50_s": round(interp_percentile(50), 4),
        f"{prefix}_p95_s": round(interp_percentile(95), 4),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="vllm_metrics.jsonl")
    parser.add_argument("--interval", type=float, default=POLL_INTERVAL)
    parser.add_argument("--url", default=VLLM_METRICS_URL)
    args = parser.parse_args()

    print(f"Polling {args.url} every {args.interval}s → {args.output}", file=sys.stderr)

    with open(args.output, "w") as out:
        prev_gen_tokens = None
        prev_prompt_tokens = None
        prev_ts = None

        while True:
            ts = time.time()
            try:
                with urllib.request.urlopen(args.url, timeout=4) as resp:
                    text = resp.read().decode("utf-8")
                metrics = parse_prometheus(text)
                metrics["ts"] = round(ts, 3)

                # Compute instantaneous token rates
                gen_tok = metrics.pop("generation_tokens_total", None)
                prompt_tok = metrics.pop("prompt_tokens_total", None)
                if gen_tok is not None and prev_gen_tokens is not None and prev_ts is not None:
                    dt = ts - prev_ts
                    if dt > 0:
                        metrics["decode_tps"] = round((gen_tok - prev_gen_tokens) / dt, 1)
                        metrics["prefill_tps"] = round((prompt_tok - prev_prompt_tokens) / dt, 1) if prompt_tok is not None and prev_prompt_tokens is not None else None
                prev_gen_tokens = gen_tok
                prev_prompt_tokens = prompt_tok
                prev_ts = ts

                out.write(json.dumps(metrics) + "\n")
                out.flush()

            except Exception as e:
                out.write(json.dumps({"ts": round(ts, 3), "error": str(e)}) + "\n")
                out.flush()

            time.sleep(args.interval)


if __name__ == "__main__":
    main()
