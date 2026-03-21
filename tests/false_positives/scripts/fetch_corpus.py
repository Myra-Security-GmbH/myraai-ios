#!/usr/bin/env python3
"""
fetch_corpus.py — Download benchmark prompt corpora to corpus/*.json

Usage:
    python3 tests/false_positives/scripts/fetch_corpus.py [--datasets all|or_bench|xstest|dolly]

Requirements:
    pip install datasets

Downloads:
    1. OR-Bench hard set   (bench-llm/or-bench)                → corpus/or_bench_hard.json
    2. XSTest safe split   (walledai/XSTest)                   → corpus/xstest_safe.json
    3. Dolly 15k sample    (databricks/databricks-dolly-15k)   → corpus/dolly_sample.json

Output format per file:
    [{"prompt": "...", "source": "<dataset>", "category": "<category_if_available>"}]
"""

import argparse
import json
import os
import random
import sys

CORPUS_DIR = os.path.join(os.path.dirname(__file__), "..", "corpus")
DOLLY_SAMPLE_SIZE = 2000
SEED = 42


def save(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
    print(f"  Saved {len(records)} prompts → {path}")


def fetch_or_bench():
    """OR-Bench: prompts that look dangerous but are objectively benign.
    Uses the 'or-bench-hard-1k' config (1 000 hard prompts)."""
    from datasets import load_dataset

    print("Fetching OR-Bench (bench-llm/or-bench, config=or-bench-hard-1k)…")
    records = []

    try:
        ds = load_dataset("bench-llm/or-bench", "or-bench-hard-1k")
        split_name = list(ds.keys())[0]
        ds = ds[split_name]
        print(f"  Loaded {len(ds)} rows from split '{split_name}'.")
    except Exception as e:
        print(f"  ERROR loading OR-Bench hard-1k: {e}")
        # Fall back to 80k config, sample 1000
        try:
            print("  Falling back to or-bench-80k, sampling 1 000…")
            ds = load_dataset("bench-llm/or-bench", "or-bench-80k")
            split_name = list(ds.keys())[0]
            ds = ds[split_name]
            random.seed(SEED)
            indices = random.sample(range(len(ds)), min(1000, len(ds)))
            ds = ds.select(indices)
        except Exception as e2:
            print(f"  ERROR loading OR-Bench fallback: {e2}")
            return

    # Detect prompt column
    prompt_col = next(
        (c for c in ("prompt", "instruction", "question", "text") if c in ds.column_names),
        ds.column_names[0],
    )
    category_col = next(
        (c for c in ("category", "label", "type", "rejection_type") if c in ds.column_names),
        None,
    )

    for row in ds:
        text = str(row[prompt_col]).strip()
        if not text:
            continue
        rec = {"prompt": text, "source": "or_bench"}
        if category_col:
            rec["category"] = str(row[category_col])
        records.append(rec)

    save(os.path.join(CORPUS_DIR, "or_bench_hard.json"), records)


def fetch_xstest():
    """XSTest: 250 safe prompts that cover topics superficially similar to harmful requests."""
    from datasets import load_dataset

    print("Fetching XSTest (walledai/XSTest)…")
    records = []

    try:
        # Try the walledai mirror first, then the original Paul/XSTest
        for slug in ("walledai/XSTest", "Paul/XSTest"):
            try:
                ds = load_dataset(slug, )
                break
            except Exception:
                continue
        else:
            print("  ERROR: could not load XSTest from either walledai/XSTest or Paul/XSTest")
            return

        split_name = list(ds.keys())[0]
        ds = ds[split_name]
        print(f"  Loaded {len(ds)} rows from split '{split_name}'.")

        # Detect prompt and label columns
        prompt_col = next(
            (c for c in ("prompt", "instruction", "text", "question") if c in ds.column_names),
            ds.column_names[0],
        )
        # Detect label/type column and print unique values to help debug filtering
        safe_col = next(
            (c for c in ("type", "label", "safe", "is_safe") if c in ds.column_names),
            None,
        )
        if safe_col:
            unique_vals = list({str(row[safe_col]) for row in ds})
            print(f"  '{safe_col}' column values: {sorted(unique_vals)}")

        for row in ds:
            # Filter to safe prompts only
            if safe_col:
                val = str(row[safe_col]).lower()
                # XSTest 'type' starts with "safe_" for safe prompts;
                # also accept "safe", "1", "true", "yes"
                # XSTest: unsafe prompts have type starting with "contrast_".
                # All other types (safe_contexts, safe_targets, figurative_language,
                # historical_events, homonyms, definitions, privacy_*, etc.) are safe.
                is_safe = (
                    not val.startswith("contrast_")
                    or val.startswith("safe")
                    or val in ("1", "true", "yes")
                )
                if not is_safe:
                    continue
            text = str(row[prompt_col]).strip()
            if not text:
                continue
            rec = {"prompt": text, "source": "xstest"}
            if safe_col:
                rec["category"] = str(row[safe_col])
            records.append(rec)

        if not records:
            print("  WARNING: label filtering removed all rows; including ALL prompts.")
            for row in ds:
                text = str(row[prompt_col]).strip()
                if text:
                    records.append({"prompt": text, "source": "xstest"})

    except Exception as e:
        print(f"  ERROR loading XSTest: {e}")
        return

    save(os.path.join(CORPUS_DIR, "xstest_safe.json"), records)


def fetch_dolly():
    """Databricks Dolly 15k: human-written, diverse benign instruction dataset."""
    from datasets import load_dataset

    print("Fetching Dolly 15k (databricks/databricks-dolly-15k)…")
    records = []

    try:
        ds = load_dataset("databricks/databricks-dolly-15k", split="train", )
        print(f"  Loaded {len(ds)} rows.")
    except Exception as e:
        print(f"  ERROR loading Dolly: {e}")
        return

    prompt_col = next(
        (c for c in ("instruction", "prompt", "text", "question") if c in ds.column_names),
        ds.column_names[0],
    )
    category_col = next(
        (c for c in ("category", "label") if c in ds.column_names),
        None,
    )

    random.seed(SEED)
    indices = random.sample(range(len(ds)), min(DOLLY_SAMPLE_SIZE, len(ds)))
    sample = ds.select(indices)

    for row in sample:
        text = str(row[prompt_col]).strip()
        if not text:
            continue
        rec = {"prompt": text, "source": "dolly_15k"}
        if category_col:
            rec["category"] = str(row[category_col])
        records.append(rec)

    save(os.path.join(CORPUS_DIR, "dolly_sample.json"), records)


FETCHERS = {
    "or_bench": fetch_or_bench,
    "xstest":   fetch_xstest,
    "dolly":    fetch_dolly,
}


def main():
    parser = argparse.ArgumentParser(description="Fetch false-positive benchmark corpora")
    parser.add_argument(
        "--datasets",
        default="all",
        help="Comma-separated list of datasets to fetch: or_bench,xstest,dolly (default: all)",
    )
    args = parser.parse_args()

    try:
        import datasets  # noqa: F401
    except ImportError:
        print("ERROR: 'datasets' package not installed.")
        print("       Run: pip install datasets")
        sys.exit(1)

    targets = (
        list(FETCHERS.keys())
        if args.datasets == "all"
        else [d.strip() for d in args.datasets.split(",")]
    )

    for name in targets:
        if name not in FETCHERS:
            print(f"Unknown dataset '{name}'. Valid options: {', '.join(FETCHERS)}")
            sys.exit(1)
        FETCHERS[name]()

    print("\nDone. Corpus files are in:", os.path.abspath(CORPUS_DIR))


if __name__ == "__main__":
    main()
