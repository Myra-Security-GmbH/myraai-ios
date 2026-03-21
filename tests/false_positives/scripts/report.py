#!/usr/bin/env python3
"""
report.py — Aggregate false positive results into a markdown report.

Usage:
    python3 tests/false_positives/scripts/report.py [--results DIR] [--gates FILE] [--fail-on-breach]

    --results DIR        Directory containing *_fp_results.json files (default: tests/false_positives/results)
    --gates FILE         JSON file with FP rate thresholds (default: tests/false_positives/gates.json)
    --fail-on-breach     Exit with code 1 if any gate threshold is exceeded

Output:
    Prints a markdown table to stdout and writes results/report.md.
"""

import argparse
import json
import os
import sys
from datetime import datetime

RESULTS_DIR = "tests/false_positives/results"
GATES_FILE  = "tests/false_positives/gates.json"

RESULT_FILES = [
    "regex_fp_results.json",
    "keyword_fp_results.json",
    "presidio_fp_results.json",
    "llm_guard_fp_results.json",
]


def load_results(results_dir):
    rows = []
    for fname in RESULT_FILES:
        path = os.path.join(results_dir, fname)
        if not os.path.exists(path):
            continue
        with open(path) as f:
            data = json.load(f)
        rows.extend(data)
    return rows


def load_gates(gates_file):
    if not os.path.exists(gates_file):
        return []
    with open(gates_file) as f:
        return json.load(f)


def top_trigger(row):
    """Return the single highest-count trigger name from any of the trigger fields."""
    for field in ("top_patterns", "top_keywords", "top_entities", "top_categories"):
        counts = row.get(field)
        if counts:
            best = max(counts, key=lambda k: counts[k])
            return f"{best} ({counts[best]})"
    return "—"


def check_gates(rows, gates):
    """Returns list of breach dicts."""
    breaches = []
    gate_index = {
        (g["detector"], g["config_id"], g["corpus"]): g["max_fp_rate"]
        for g in gates
    }
    for row in rows:
        key = (row["detector"], row["config_id"], row["corpus"])
        max_rate = gate_index.get(key)
        if max_rate is not None and row["fp_rate"] > max_rate:
            breaches.append({
                "detector":  row["detector"],
                "config_id": row["config_id"],
                "corpus":    row["corpus"],
                "fp_rate":   row["fp_rate"],
                "max_rate":  max_rate,
            })
    return breaches


def render_table(rows, breaches):
    breach_keys = {
        (b["detector"], b["config_id"], b["corpus"])
        for b in breaches
    }

    lines = []
    lines.append("## False Positive Rate Report")
    lines.append(f"\n_Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}_\n")

    lines.append("| Detector | Config | Corpus | Total | FP count | FP rate | Top trigger |")
    lines.append("|---|---|---|---|---|---|---|")

    for row in rows:
        key     = (row["detector"], row["config_id"], row["corpus"])
        breach  = " ⚠️" if key in breach_keys else ""
        fp_rate = f"{row['fp_rate']:.1f}%{breach}"
        lines.append(
            f"| {row['detector']} | {row['config_id']} | {row['corpus']} "
            f"| {row['total']} | {row['fp_count']} | {fp_rate} | {top_trigger(row)} |"
        )

    if breaches:
        lines.append("\n### Gate Breaches ⚠️\n")
        lines.append("| Detector | Config | Corpus | FP rate | Threshold |")
        lines.append("|---|---|---|---|---|")
        for b in breaches:
            lines.append(
                f"| {b['detector']} | {b['config_id']} | {b['corpus']} "
                f"| {b['fp_rate']:.1f}% | {b['max_rate']:.1f}% |"
            )

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results",       default=RESULTS_DIR)
    parser.add_argument("--gates",         default=GATES_FILE)
    parser.add_argument("--fail-on-breach", action="store_true")
    args = parser.parse_args()

    rows = load_results(args.results)
    if not rows:
        print("No result files found in", args.results)
        print("Run the test scripts first.")
        sys.exit(0)

    gates    = load_gates(args.gates)
    breaches = check_gates(rows, gates)
    report   = render_table(rows, breaches)

    print(report)

    out_path = os.path.join(args.results, "report.md")
    with open(out_path, "w") as f:
        f.write(report)
    print(f"\nReport written → {out_path}")

    if args.fail_on_breach and breaches:
        print(f"\n{len(breaches)} gate breach(es) detected. Failing CI.")
        sys.exit(1)


if __name__ == "__main__":
    main()
