#!/usr/bin/env bash
# run_all.sh — Orchestrate the full false positive test suite.
#
# Usage (from repo root):
#   bash tests/false_positives/run_all.sh [--fetch] [--tier2] [--fail-on-breach]
#
#   --fetch         Download corpus files before running (requires: pip install datasets)
#   --tier2         Also run Presidio and llm_guard tests (sidecars must be running)
#   --fail-on-breach Exit non-zero if any gate threshold is breached

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

FETCH=0
TIER2=0
FAIL_ON_BREACH=0

for arg in "$@"; do
  case "$arg" in
    --fetch)          FETCH=1 ;;
    --tier2)          TIER2=1 ;;
    --fail-on-breach) FAIL_ON_BREACH=1 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "════════════════════════════════════════════════════════════════════════"
echo " AI Gateway — False Positive Benchmark Suite"
echo "════════════════════════════════════════════════════════════════════════"

# ── Step 1: fetch corpus (optional) ──────────────────────────────────────────
if [[ $FETCH -eq 1 ]]; then
  echo ""
  echo "── Step 1: Fetching corpora ──────────────────────────────────────────"
  python3 tests/false_positives/scripts/fetch_corpus.py
else
  echo ""
  echo "── Step 1: Skipping corpus fetch (pass --fetch to download) ──────────"
  echo "   Corpus files expected in tests/false_positives/corpus/"
fi

# ── Step 2: Tier 1 — regex FP test ──────────────────────────────────────────
echo ""
echo "── Step 2: Regex detector FP sweep ──────────────────────────────────"
resty tests/false_positives/test_regex_fp.lua

# ── Step 3: Tier 1 — keyword FP test ────────────────────────────────────────
echo ""
echo "── Step 3: Keyword detector FP sweep ────────────────────────────────"
resty tests/false_positives/test_keyword_fp.lua

# ── Steps 4-6: Tier 2 — Presidio, pii_protector, llm_guard (optional) ───────
if [[ $TIER2 -eq 1 ]]; then
  echo ""
  echo "── Step 4: Presidio FP sweep ─────────────────────────────────────────"
  python3 tests/false_positives/test_presidio_fp.py

  echo ""
  echo "── Step 5: pii_protector FP sweep ───────────────────────────────────"
  python3 tests/false_positives/test_pii_protector_fp.py

  echo ""
  echo "── Step 6: llm_guard / prompt_guard FP sweep ────────────────────────"
  python3 tests/false_positives/test_llm_guard_fp.py
else
  echo ""
  echo "── Steps 4-6: Skipping Tier 2 tests (pass --tier2 to include) ───────"
  echo "   Requires Presidio at :5002 and llm_guard / prompt_guard at :8083"
fi

# ── Step 7: Generate report ──────────────────────────────────────────────────
echo ""
echo "── Step 7: Generating report ─────────────────────────────────────────"
BREACH_FLAG=""
if [[ $FAIL_ON_BREACH -eq 1 ]]; then
  BREACH_FLAG="--fail-on-breach"
fi
python3 tests/false_positives/scripts/report.py \
  --results tests/false_positives/results \
  --gates   tests/false_positives/gates.json \
  $BREACH_FLAG

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo " Done. Full report: tests/false_positives/results/report.md"
echo " Tier 2 note: Presidio (GPU OOM risk if prompt_guard is loaded)."
echo "              Stop the prompt_guard container before running --tier2."
echo "════════════════════════════════════════════════════════════════════════"
