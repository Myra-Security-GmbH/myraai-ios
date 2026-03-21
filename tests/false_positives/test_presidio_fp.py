#!/usr/bin/env python3
"""
test_presidio_fp.py — Sweep Presidio score thresholds across corpora.

Requires: Presidio analyzer running at http://127.0.0.1:5002 (or --url override).
          pip install requests

Run from repo root:
    python3 tests/false_positives/test_presidio_fp.py

Results → tests/false_positives/results/presidio_fp_results.json
"""

import argparse
import json
import os
import sys
import time

CORPUS_DIR  = "tests/false_positives/corpus"
RESULTS_DIR = "tests/false_positives/results"

THRESHOLDS    = [0.5, 0.6, 0.7, 0.8, 0.9]
ENTITY_COMBOS = [
    # (label, entities_list — None means all entities)
    ("all_entities",  None),
    ("person_email",  ["PERSON", "EMAIL_ADDRESS"]),
    ("pii_core",      ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "LOCATION"]),
    # pii_focused: excludes high-FP entities (PERSON, LOCATION, DATE_TIME, NRP).
    # This mirrors the effect of HIGH_FP_ENTITY_THRESHOLDS=0.9 in presidio.lua.
    # Targets only genuinely sensitive data that rarely appears in benign text.
    ("pii_focused",   ["EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN", "CREDIT_CARD",
                       "US_BANK_NUMBER", "IBAN_CODE", "US_PASSPORT",
                       "US_DRIVER_LICENSE", "US_ITIN", "CRYPTO"]),

    # ── Per-entity sweep ───────────────────────────────────────────────────────
    # Each entry isolates a single entity type so we can measure its individual
    # FP rate.  Results at threshold=0.7 are used to assign fp_risk ratings in
    # PRESIDIO_ENTITY_CATALOG in GuardrailBuilder.tsx.
    ("e_EMAIL_ADDRESS",     ["EMAIL_ADDRESS"]),
    ("e_PHONE_NUMBER",      ["PHONE_NUMBER"]),
    ("e_US_SSN",            ["US_SSN"]),
    ("e_CREDIT_CARD",       ["CREDIT_CARD"]),
    ("e_US_BANK_NUMBER",    ["US_BANK_NUMBER"]),
    ("e_IBAN_CODE",         ["IBAN_CODE"]),
    ("e_US_PASSPORT",       ["US_PASSPORT"]),
    ("e_US_DRIVER_LICENSE", ["US_DRIVER_LICENSE"]),
    ("e_US_ITIN",           ["US_ITIN"]),
    ("e_CRYPTO",            ["CRYPTO"]),
    ("e_IP_ADDRESS",        ["IP_ADDRESS"]),
    ("e_MEDICAL_LICENSE",   ["MEDICAL_LICENSE"]),
    ("e_URL",               ["URL"]),
    ("e_PERSON",            ["PERSON"]),
    ("e_LOCATION",          ["LOCATION"]),
    ("e_DATE_TIME",         ["DATE_TIME"]),
    ("e_NRP",               ["NRP"]),
]


def load_corpus(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def analyze(text, analyzer_url, score_threshold, entities, timeout=5):
    """POST to Presidio /analyze. Returns list of entity detections."""
    import requests
    payload = {
        "text":            text,
        "language":        "en",
        "score_threshold": score_threshold,
    }
    if entities is not None:
        payload["entities"] = entities
    try:
        r = requests.post(
            f"{analyzer_url}/analyze",
            json=payload,
            timeout=timeout,
        )
        r.raise_for_status()
        return r.json()
    except Exception as e:
        return None, str(e)


def check_health(url, timeout=3):
    import requests
    for path in ("/health", "/"):
        try:
            r = requests.get(url + path, timeout=timeout)
            if r.status_code < 500:
                return True
        except Exception:
            pass
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url",   default="http://127.0.0.1:5002", help="Presidio analyzer URL")
    parser.add_argument("--limit", type=int, default=500,
                        help="Max prompts per corpus (default 500, use 0 for all)")
    args = parser.parse_args()

    try:
        import requests  # noqa: F401
    except ImportError:
        print("ERROR: 'requests' not installed. Run: pip install requests")
        sys.exit(1)

    if not check_health(args.url):
        print(f"SKIP: Presidio analyzer not reachable at {args.url}")
        print("      Start it with:")
        print("        docker run -p 5002:5002 mcr.microsoft.com/presidio-analyzer:latest")
        sys.exit(0)

    print(f"Presidio analyzer reachable at {args.url}")
    os.makedirs(RESULTS_DIR, exist_ok=True)

    corpus_files = [
        ("or_bench_hard", os.path.join(CORPUS_DIR, "or_bench_hard.json")),
        ("xstest_safe",   os.path.join(CORPUS_DIR, "xstest_safe.json")),
        ("dolly_sample",  os.path.join(CORPUS_DIR, "dolly_sample.json")),
        ("handcrafted",   os.path.join(CORPUS_DIR, "handcrafted.json")),
    ]

    all_results = []
    col_w = 22

    header = f"{'corpus':<{col_w}} {'entities':<16} {'threshold':>10} {'total':>8} {'fp_count':>8} {'fp%':>7}"
    print("─" * len(header))
    print(header)
    print("─" * len(header))

    for corpus_name, corpus_path in corpus_files:
        prompts = load_corpus(corpus_path)
        if prompts is None:
            print(f"SKIP {corpus_name} (not found)")
            continue

        if args.limit and len(prompts) > args.limit:
            prompts = prompts[: args.limit]

        # Cache raw Presidio results at threshold=0.0 to avoid repeat API calls.
        # We'll re-filter per threshold and entity combo in Python.
        print(f"\n  Pre-fetching {len(prompts)} prompts for {corpus_name}…", flush=True)
        raw_cache = []  # list of (prompt_text, entities_list_at_threshold_0)
        for i, entry in enumerate(prompts):
            text = (entry.get("prompt") or entry.get("instruction") or entry.get("text") or "").strip()
            if not text:
                raw_cache.append([])
                continue
            result = analyze(text, args.url, score_threshold=0.0, entities=None)
            if result is None or isinstance(result, tuple):
                raw_cache.append([])
            else:
                raw_cache.append(result)
            if (i + 1) % 100 == 0:
                print(f"    {i+1}/{len(prompts)}", flush=True)

        for threshold in THRESHOLDS:
            for entity_label, entity_filter in ENTITY_COMBOS:
                fp_count = 0
                entity_counts = {}

                for detections in raw_cache:
                    # Apply threshold and entity filter post-hoc
                    filtered = [
                        d for d in detections
                        if d.get("score", 0) >= threshold
                        and (entity_filter is None or d.get("entity_type") in entity_filter)
                    ]
                    if filtered:
                        fp_count += 1
                        for d in filtered:
                            et = d.get("entity_type", "?")
                            entity_counts[et] = entity_counts.get(et, 0) + 1

                total   = len(prompts)
                fp_rate = round(fp_count / total * 100, 2) if total else 0.0

                print(f"{corpus_name:<{col_w}} {entity_label:<16} {threshold:>10.1f} {total:>8} {fp_count:>8} {fp_rate:>6.1f}%")

                all_results.append({
                    "corpus":         corpus_name,
                    "detector":       "presidio",
                    "config_id":      f"threshold={threshold}_entities={entity_label}",
                    "score_threshold": threshold,
                    "entities":       entity_filter,
                    "total":          total,
                    "fp_count":       fp_count,
                    "fp_rate":        fp_rate,
                    "top_entities":   entity_counts,
                })

    print("\n" + "─" * len(header))
    out_path = os.path.join(RESULTS_DIR, "presidio_fp_results.json")
    with open(out_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults → {out_path}")


if __name__ == "__main__":
    main()
