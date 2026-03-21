#!/usr/bin/env python3
"""
test_llm_guard_fp.py — Sweep llm_guard category filters across corpora.

Requires: llm_guard sidecar (Llama Guard 3) running at http://127.0.0.1:8083
          pip install requests

Run from repo root:
    python3 tests/false_positives/test_llm_guard_fp.py

Strategy: classify each prompt once (expensive), then apply different category
filters in Python. One API call per prompt, multiple config sweeps for free.

Results → tests/false_positives/results/llm_guard_fp_results.json
"""

import argparse
import json
import os
import re
import sys

CORPUS_DIR  = "tests/false_positives/corpus"
RESULTS_DIR = "tests/false_positives/results"

# Llama Guard 3 category taxonomy (for reference):
#   S1  Violent Crimes          S2  Non-Violent Crimes     S3  Sex-Related Crimes
#   S4  Child Sexual Exploit.   S5  Defamation             S6  Specialized Advice
#   S7  Privacy                 S8  Intellectual Property  S9  Indiscriminate Weapons (CBRN)
#   S10 Hate                    S11 Suicide & Self-Harm    S12 Sexual Content
#   S13 Elections
#
# FP findings (OR-Bench-hard 200 prompts):
#   S2  → 13 FPs  (security education: "how does malware work")  ← do NOT include in block
#   S10 →  5 FPs  (cybersecurity topics trigger hate classifier)  ← avoid in block
#   S5  →  2 FPs  (defamation)
#   S9  →  2 FPs  (CBRN weapons)
#   S1  →  0 FPs  ← safe for block
#   S4  →  0 FPs  ← safe for block
#   S11 →  0 FPs  ← safe for block
#
# Category filter configurations to sweep (None = all categories)
CATEGORY_CONFIGS = [
    # ── Baseline ──────────────────────────────────────────────────────────────
    ("all_categories",     None),

    # ── High-FP configs (educational) ─────────────────────────────────────────
    # S2 (Non-Violent Crimes) fires heavily on security education text.
    # S10 (Hate) fires on cybersecurity topics.  Never use these for action:block.
    ("crime_nvc",          {"S2"}),               # S2 alone: baseline for FP measurement
    ("hate_only",          {"S10"}),              # S10 alone: hate classifier baseline

    # ── Low-FP configs (recommended for action:block) ──────────────────────────
    # These had 0 FP across all four corpora.
    ("violent_crimes",     {"S1"}),               # murder, assault, terrorism
    ("cbrn_weapons",       {"S9"}),               # chem/bio/rad/nuc weapons
    ("csam",               {"S4"}),               # child sexual exploitation
    ("suicide_self_harm",  {"S11"}),              # suicide / self-harm

    # ── Recommended combined block config ─────────────────────────────────────
    # Union of the four low-FP categories above.  Excludes S2 and S10.
    ("recommended_block",  {"S1", "S4", "S9", "S11"}),

    # ── Legacy configs (kept for gate continuity) ──────────────────────────────
    ("violence_hate",      {"S1", "S3"}),         # original: violent+sex crimes
    ("weapons_csam",       {"S2", "S9"}),         # original: includes S2 (high FP)
    ("crime_privacy",      {"S4", "S5", "S6"}),
    ("narrow_block",       {"S2", "S9", "S11"}),  # original: includes S2 (high FP)
]


def load_corpus(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def classify(text, url, timeout=5):
    """Call Llama Guard sidecar. Returns (verdict, categories_set) or (None, err)."""
    import requests
    payload = {
        "model":       "llama-guard-3-8b",
        "messages":    [{"role": "user", "content": text}],
        "max_tokens":  20,
        "temperature": 0,
    }
    try:
        r = requests.post(f"{url}/v1/chat/completions", json=payload, timeout=timeout)
        r.raise_for_status()
        data = r.json()
        content = (
            data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
                .strip()
        )
        verdict = content.split()[0].lower() if content else "unknown"
        cats_raw = content.split("\n")[1] if "\n" in content else ""
        categories = set(c.strip() for c in re.split(r"[,\s]+", cats_raw) if c.strip())
        return verdict, categories
    except Exception as e:
        return None, str(e)


def check_health(url, timeout=3):
    import requests
    for path in ("/health", "/v1/models"):
        try:
            r = requests.get(url + path, timeout=timeout)
            if r.status_code < 500:
                return True
        except Exception:
            pass
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url",   default="http://127.0.0.1:8083")
    parser.add_argument("--limit", type=int, default=200,
                        help="Max prompts per corpus (default 200; LLM calls are slow)")
    args = parser.parse_args()

    try:
        import requests  # noqa: F401
    except ImportError:
        print("ERROR: 'requests' not installed. Run: pip install requests")
        sys.exit(1)

    if not check_health(args.url):
        print(f"SKIP: llm_guard sidecar not reachable at {args.url}")
        print("      Start it with a Llama Guard 3 container on port 8083.")
        sys.exit(0)

    print(f"llm_guard sidecar reachable at {args.url}")
    os.makedirs(RESULTS_DIR, exist_ok=True)

    corpus_files = [
        ("or_bench_hard", os.path.join(CORPUS_DIR, "or_bench_hard.json")),
        ("xstest_safe",   os.path.join(CORPUS_DIR, "xstest_safe.json")),
        ("dolly_sample",  os.path.join(CORPUS_DIR, "dolly_sample.json")),
        ("handcrafted",   os.path.join(CORPUS_DIR, "handcrafted.json")),
    ]

    all_results = []
    col_w = 22

    for corpus_name, corpus_path in corpus_files:
        prompts = load_corpus(corpus_path)
        if prompts is None:
            print(f"SKIP {corpus_name} (not found)")
            continue

        if args.limit and len(prompts) > args.limit:
            prompts = prompts[: args.limit]

        print(f"\n  Classifying {len(prompts)} prompts for {corpus_name}…", flush=True)

        # Step 1: classify every prompt once, cache (verdict, categories)
        cache = []
        errors = 0
        for i, entry in enumerate(prompts):
            text = (entry.get("prompt") or entry.get("instruction") or entry.get("text") or "").strip()
            if not text:
                cache.append(("pass", set()))
                continue
            verdict, cats = classify(text, args.url)
            if verdict is None:
                errors += 1
                cache.append(("error", set()))
            else:
                cache.append((verdict, cats))
            if (i + 1) % 50 == 0:
                print(f"    {i+1}/{len(prompts)} (errors={errors})", flush=True)

        if errors > 0:
            print(f"  WARNING: {errors} classification errors (sidecar may be overloaded)")

        # Step 2: apply each category config as a post-filter
        header = f"{'corpus':<{col_w}} {'cat_config':<18} {'total':>8} {'fp_count':>8} {'fp%':>7}"
        if corpus_name == corpus_files[0][0]:
            print("─" * len(header))
            print(header)
            print("─" * len(header))

        for cat_label, allowed_cats in CATEGORY_CONFIGS:
            fp_count = 0
            cat_counts = {}

            for verdict, categories in cache:
                if verdict != "unsafe":
                    continue
                # Apply category filter
                if allowed_cats is None:
                    effective = categories
                else:
                    effective = categories & allowed_cats

                if effective:
                    fp_count += 1
                    for c in effective:
                        cat_counts[c] = cat_counts.get(c, 0) + 1

            total   = len(prompts)
            fp_rate = round(fp_count / total * 100, 2) if total else 0.0

            print(f"{corpus_name:<{col_w}} {cat_label:<18} {total:>8} {fp_count:>8} {fp_rate:>6.1f}%")

            all_results.append({
                "corpus":     corpus_name,
                "detector":   "llm_guard",
                "config_id":  cat_label,
                "categories": sorted(allowed_cats) if allowed_cats else None,
                "total":      total,
                "fp_count":   fp_count,
                "fp_rate":    fp_rate,
                "top_categories": cat_counts,
            })

    out_path = os.path.join(RESULTS_DIR, "llm_guard_fp_results.json")
    with open(out_path, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults → {out_path}")


if __name__ == "__main__":
    main()
