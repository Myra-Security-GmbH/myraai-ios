#!/usr/bin/env bash
# scripts/sync_openrouter_models.sh
#
# Fetches the OpenRouter model catalog and upserts all models with pricing
# into the gateway's config.db (model_price table, provider = "openrouter").
#
# Usage:
#   ./scripts/sync_openrouter_models.sh [/path/to/config.db] [/path/to/models.json]
#
# If no DB path is given, defaults to data/config.db.
# If no JSON path is given, downloads from OpenRouter's public API.
#
# Requires: python3, sqlite3, curl (only when downloading)

set -euo pipefail

DB="${1:-data/config.db}"
JSON_FILE="${2:-}"
OPENROUTER_URL="https://openrouter.ai/api/v1/models"

# ── fetch ────────────────────────────────────────────────────────────────────

if [[ -z "$JSON_FILE" ]]; then
    TMP_JSON=$(mktemp /tmp/openrouter_models.XXXXXX.json)
    trap 'rm -f "$TMP_JSON"' EXIT
    echo "Fetching $OPENROUTER_URL ..."
    curl -sSfL \
        -H "Accept: application/json" \
        "$OPENROUTER_URL" -o "$TMP_JSON"
    JSON_FILE="$TMP_JSON"
fi

echo "Parsing $(wc -c < "$JSON_FILE") bytes from $JSON_FILE ..."

# ── transform → SQL, then apply ──────────────────────────────────────────────

TMP_SQL=$(mktemp /tmp/openrouter_models.XXXXXX.sql)
trap 'rm -f "${TMP_JSON:-}" "$TMP_SQL"' EXIT

python3 - "$JSON_FILE" "$TMP_SQL" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

models = data.get("data", [])
rows   = 0
lines  = ["BEGIN;"]

for entry in models:
    model_id = entry.get("id", "")
    if not model_id:
        continue

    pricing = entry.get("pricing") or {}
    # OpenRouter prices are per-token strings (e.g. "0.000001"); convert to per-1k
    def per_1k(val):
        try:
            v = float(val)
            return round(v * 1000, 10)
        except (TypeError, ValueError):
            return None

    inp_1k = per_1k(pricing.get("prompt"))
    out_1k = per_1k(pricing.get("completion"))

    # Skip entries without usable pricing (set to 0 for free/unknown models)
    if inp_1k is None:
        inp_1k = 0.0
    if out_1k is None:
        out_1k = 0.0

    esc_model = model_id.replace("'", "''")
    now = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    lines.append(
        f"INSERT OR REPLACE INTO model_price "
        f"(provider,model,input_per_1k,output_per_1k,cache_write_per_1k,cache_read_per_1k,updated_at) "
        f"VALUES ('openrouter','{esc_model}',{inp_1k},{out_1k},NULL,NULL,{now});"
    )
    rows += 1

lines.append("COMMIT;")

with open(sys.argv[2], "w") as out:
    out.write("\n".join(lines))

print(f"Generated {rows} INSERT OR REPLACE statements.")
PYEOF

echo "Applying SQL to $DB ..."
sqlite3 "$DB" < "$TMP_SQL"
echo "Sync complete."
