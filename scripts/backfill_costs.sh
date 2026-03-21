#!/usr/bin/env bash
# scripts/backfill_costs.sh — recompute cost_usd for existing log records
#
# Joins logs.db with model_pricing in config.db and updates cost_usd using
# current prices.  Only updates records where the model is known; records for
# unknown models are left unchanged.
#
# Note: cache_creation_tokens and cache_read_tokens are not stored in logs, so
# cost is derived from input_tokens and output_tokens only.
#
# Usage:
#   ./scripts/backfill_costs.sh              # update records where cost_usd = 0
#   ./scripts/backfill_costs.sh --all        # recompute every record

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOGS_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/logs.db"
CFG_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/config.db"
ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) ALL=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

for db in "$LOGS_DB" "$CFG_DB"; do
    if [[ ! -f "$db" ]]; then
        echo "Not found: $db" >&2
        exit 1
    fi
done

if [[ $ALL -eq 1 ]]; then
    WHERE_CLAUSE="1=1"
    echo "Recomputing cost_usd for ALL records..."
else
    WHERE_CLAUSE="l.cost_usd = 0"
    echo "Recomputing cost_usd for records where cost_usd = 0..."
fi

UPDATED=$(sqlite3 "$LOGS_DB" "
ATTACH DATABASE '$CFG_DB' AS cfg;

UPDATE request_log AS l
SET cost_usd = (
    SELECT
        (CAST(l.input_tokens          AS REAL) / 1000.0 * p.input_per_1k)
      + (CAST(l.output_tokens         AS REAL) / 1000.0 * p.output_per_1k)
      + (CAST(COALESCE(l.cache_creation_tokens, 0) AS REAL) / 1000.0 * COALESCE(p.cache_write_per_1k, p.input_per_1k))
      + (CAST(COALESCE(l.cache_read_tokens,     0) AS REAL) / 1000.0 * COALESCE(p.cache_read_per_1k,  0))
    FROM cfg.model_pricing p
    WHERE p.provider = l.provider
      AND p.model    = l.model
)
WHERE $WHERE_CLAUSE
  AND EXISTS (
    SELECT 1 FROM cfg.model_pricing p
    WHERE p.provider = l.provider
      AND p.model    = l.model
      AND typeof(p.input_per_1k)  = 'real'
      AND typeof(p.output_per_1k) = 'real'
  );

SELECT changes();
")

echo "Updated ${UPDATED} record(s)."
