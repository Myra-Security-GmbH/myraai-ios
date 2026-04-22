#!/usr/bin/env python3
"""
analyse.py — Post-run analysis of perf_*.jsonl files.

Reads raw measurement JSONL produced by run_perf.py and generates
a detailed statistics report. Useful for re-analysing without re-running tests.

Usage:
  python3 analyse.py results/perf_20260422_123456.jsonl
  python3 analyse.py results/perf_20260422_123456.jsonl --format markdown
"""

import argparse
import json
import pathlib
import statistics
import sys
from collections import defaultdict


def load(path: pathlib.Path) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = (len(s) - 1) * p / 100
    lo, hi = int(idx), min(int(idx) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)


def throughput(rows: list[dict]) -> float:
    good = [r for r in rows if not r.get("error_type") and r.get("status") == 200]
    if len(good) < 2:
        return 0.0
    elapsed = max(r["end_time"] for r in good) - min(r["start_time"] for r in good)
    return len(good) / elapsed if elapsed > 0 else 0.0


def analyse_group(rows: list[dict]) -> dict:
    good = [r for r in rows if not r.get("error_type") and r.get("status") == 200]
    wall  = [r["wall_ms"] for r in good if r.get("wall_ms")]
    ttft  = [r["ttft_ms"] for r in good if r.get("ttft_ms")]
    dtps  = [r["decode_tps"] for r in good if r.get("decode_tps")]
    tok_o = [r["tokens_out"] for r in good if r.get("tokens_out")]
    tok_i = [r["tokens_in"]  for r in good if r.get("tokens_in")]

    def p(vals, pct): return round(percentile(vals, pct), 1) if vals else None

    return {
        "n_total":        len(rows),
        "n_ok":           len(good),
        "error_rate_pct": round((1 - len(good) / len(rows)) * 100, 1) if rows else 0,
        "cached_pct":     round(sum(1 for r in good if r.get("cached")) / len(good) * 100, 1) if good else 0,
        "wall": {"p50": p(wall,50), "p90": p(wall,90), "p95": p(wall,95), "p99": p(wall,99), "max": round(max(wall),1) if wall else None},
        "ttft": {"p50": p(ttft,50), "p90": p(ttft,90), "p95": p(ttft,95)},
        "decode_tps": {"p50": p(dtps,50), "p95": p(dtps,95), "mean": round(statistics.mean(dtps),1) if dtps else None},
        "tokens_out": {"mean": round(statistics.mean(tok_o),1) if tok_o else None, "p95": p(tok_o,95)},
        "tokens_in":  {"mean": round(statistics.mean(tok_i),1) if tok_i else None},
        "throughput_rps": round(throughput(rows), 3),
        "throughput_rpm": round(throughput(rows) * 60, 1),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", help="perf_*.jsonl file to analyse")
    parser.add_argument("--format", choices=["text", "markdown"], default="text")
    args = parser.parse_args()

    path = pathlib.Path(args.input)
    if not path.exists():
        sys.exit(f"ERROR: {path} not found")

    rows = load(path)
    print(f"Loaded {len(rows)} measurements from {path.name}\n")

    # Group by (scenario_key, level_key)
    groups = defaultdict(list)
    for r in rows:
        key = (r.get("scenario_key", r.get("scenario", "?")),
               str(r.get("level_key", r.get("concurrency", "?"))))
        groups[key].append(r)

    md = args.format == "markdown"

    for (sc, lv), grp_rows in sorted(groups.items()):
        g = analyse_group(grp_rows)
        c = int(lv) if lv.isdigit() else lv

        if md:
            print(f"### {sc} — level={lv}")
            print(f"| Metric | Value |")
            print(f"|---|---|")
            print(f"| n | {g['n_ok']}/{g['n_total']} ok |")
            print(f"| error rate | {g['error_rate_pct']}% |")
            print(f"| cached | {g['cached_pct']}% |")
            print(f"| wall p50/p95/p99 | {g['wall']['p50']}/{g['wall']['p95']}/{g['wall']['p99']} ms |")
            if g['ttft']['p50']:
                print(f"| TTFT p50/p95 | {g['ttft']['p50']}/{g['ttft']['p95']} ms |")
            if g['decode_tps']['p50']:
                print(f"| decode tps p50 | {g['decode_tps']['p50']} tok/s |")
            print(f"| throughput | {g['throughput_rps']} req/s ({g['throughput_rpm']} req/min) |")
            print()
        else:
            print(f"[{sc} / c={c}]  n={g['n_ok']}/{g['n_total']}  err={g['error_rate_pct']}%  "
                  f"wall p50/p95/p99={g['wall']['p50']}/{g['wall']['p95']}/{g['wall']['p99']} ms  "
                  f"ttft_p50={g['ttft']['p50']} ms  "
                  f"decode_tps_p50={g['decode_tps']['p50']}  "
                  f"tput={g['throughput_rps']}/s ({g['throughput_rpm']}/min)")


if __name__ == "__main__":
    main()
