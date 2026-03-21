#!/usr/bin/env python3
"""
test_presidio_fp.py — Sweep Presidio score thresholds across corpora.

Requires: Presidio analyzer running at http://127.0.0.1:5002 (or --url override).
          pip install requests

Run from repo root:
    python3 tests/false_positives/test_presidio_fp.py [--pct 20] [--min-full 10000] [--seed 42]

--pct N         Sample N% of each corpus above --min-full size (default 100 = all).
                Each prompt is included independently with this probability.
--min-full N    Corpora with <= N prompts are always run in full (default 10000).
                Only larger corpora are subject to --pct sampling.

Results → tests/false_positives/results/presidio_fp_results.json
"""

import argparse
import json
import os
import random
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
    # Targets only genuinely sensitive data that rarely appears in benign text.
    ("pii_focused",   ["EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN", "CREDIT_CARD",
                       "US_BANK_NUMBER", "IBAN_CODE", "US_PASSPORT",
                       "US_DRIVER_LICENSE", "US_ITIN", "CRYPTO",
                       "IP_ADDRESS", "MEDICAL_LICENSE", "URL"]),

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
    parser.add_argument("--url",      default="http://127.0.0.1:5002",
                        help="Presidio analyzer URL")
    parser.add_argument("--pct",      type=float, default=100.0,
                        help="Percentage of large corpora to sample (default 100 = all). "
                             "Each prompt is included independently with this probability.")
    parser.add_argument("--min-full", type=int, default=10000,
                        help="Corpora with <= this many prompts are always run in full "
                             "regardless of --pct (default 10000).")
    parser.add_argument("--seed",     type=int, default=42,
                        help="Random seed for --pct sampling (default 42)")
    args = parser.parse_args()

    try:
        import requests  # noqa: F401
    except ImportError:
        print("ERROR: 'requests' not installed. Run: pip install requests")
        sys.exit(1)

    if not check_health(args.url):
        print(f"SKIP: Presidio analyzer not reachable at {args.url}")
        print("      Start it with:")
        print("        docker start aig-presidio-analyzer")
        sys.exit(0)

    print(f"Presidio analyzer reachable at {args.url}")
    if args.pct < 100.0:
        print(f"Sampling {args.pct}% of corpora larger than {args.min_full:,} prompts (seed={args.seed})")
    os.makedirs(RESULTS_DIR, exist_ok=True)

    corpus_files = [
        ("or_bench_hard", os.path.join(CORPUS_DIR, "or_bench_hard.json")),
        ("or_bench_80k",  os.path.join(CORPUS_DIR, "or_bench_80k.json")),
        ("xstest_safe",   os.path.join(CORPUS_DIR, "xstest_safe.json")),
        ("dolly_sample",  os.path.join(CORPUS_DIR, "dolly_sample.json")),
        ("no_robots",     os.path.join(CORPUS_DIR, "no_robots.json")),
        ("lima",          os.path.join(CORPUS_DIR, "lima.json")),
        ("oasst2",        os.path.join(CORPUS_DIR, "oasst2.json")),
        ("handcrafted",   os.path.join(CORPUS_DIR, "handcrafted.json")),
    ]

    all_results   = []
    total_fetched = 0
    global_start  = time.time()
    col_w         = 22
    rng           = random.Random(args.seed)

    header = (f"{'corpus':<{col_w}} {'entities':<20} {'threshold':>10} "
              f"{'total':>8} {'fp_count':>8} {'fp%':>7}")
    print("─" * len(header))
    print(header)
    print("─" * len(header))

    for corpus_name, corpus_path in corpus_files:
        all_prompts = load_corpus(corpus_path)
        if all_prompts is None:
            print(f"SKIP {corpus_name} (not found)")
            continue

        # Apply --pct only to corpora larger than --min-full
        if args.pct < 100.0 and len(all_prompts) > args.min_full:
            keep_prob = args.pct / 100.0
            prompts   = [p for p in all_prompts if rng.random() < keep_prob]
            sampled   = True
        else:
            prompts = all_prompts
            sampled = False

        if not prompts:
            print(f"SKIP {corpus_name} (0 prompts after sampling)")
            continue

        # Fetch all detections at threshold=0.0 once; filter post-hoc per threshold/entity combo.
        corpus_start = time.time()
        label_str    = f"{len(prompts)}/{len(all_prompts)}" if sampled else str(len(prompts))
        print(f"\n  Pre-fetching {label_str} prompts for {corpus_name}…", flush=True)

        raw_cache = []
        errors    = 0

        for i, entry in enumerate(prompts):
            text = (entry.get("prompt") or entry.get("instruction") or entry.get("text") or "").strip()
            if not text:
                raw_cache.append([])
                continue
            result = analyze(text, args.url, score_threshold=0.0, entities=None)
            if result is None or isinstance(result, tuple):
                raw_cache.append([])
                errors += 1
            else:
                raw_cache.append(result)
            if (i + 1) % 100 == 0:
                elapsed = time.time() - corpus_start
                rate    = (i + 1) / elapsed if elapsed > 0 else 0
                eta     = (len(prompts) - i - 1) / rate if rate > 0 else 0
                print(f"    {i+1}/{len(prompts)}  {rate:.1f} req/s  ETA {eta/60:.1f}m", flush=True)

        corpus_elapsed = time.time() - corpus_start
        total_fetched += len(prompts)
        rate_corpus    = len(prompts) / corpus_elapsed if corpus_elapsed > 0 else 0
        if errors:
            print(f"  WARNING: {errors} errors (empty detections used as fallback)")
        print(f"  Fetched {len(prompts)} prompts in {corpus_elapsed:.1f}s ({rate_corpus:.2f} req/s)", flush=True)

        for threshold in THRESHOLDS:
            for entity_label, entity_filter in ENTITY_COMBOS:
                fp_count      = 0
                entity_counts = {}

                for detections in raw_cache:
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

                print(f"{corpus_name:<{col_w}} {entity_label:<20} {threshold:>10.1f} "
                      f"{total:>8} {fp_count:>8} {fp_rate:>6.1f}%")

                all_results.append({
                    "corpus":          corpus_name,
                    "detector":        "presidio",
                    "config_id":       f"threshold={threshold}_entities={entity_label}",
                    "score_threshold": threshold,
                    "entities":        entity_filter,
                    "total":           total,
                    "fp_count":        fp_count,
                    "fp_rate":         fp_rate,
                    "top_entities":    entity_counts,
                })

    print("\n" + "─" * len(header))
    global_elapsed = time.time() - global_start
    avg_rate       = total_fetched / global_elapsed if global_elapsed > 0 else 0
    print(f"\nTotal: {total_fetched:,} prompts fetched in {global_elapsed/60:.1f}m ({avg_rate:.2f} req/s avg)")
    if avg_rate > 0 and args.pct < 100.0:
        full_size = 111268
        eta_full  = full_size / avg_rate
        print(f"Projected full-corpus ({full_size:,} prompts) at this rate: {eta_full/3600:.1f}h")

    out_path = os.path.join(RESULTS_DIR, "presidio_fp_results.json")
    with open(out_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults → {out_path}")


if __name__ == "__main__":
    main()
