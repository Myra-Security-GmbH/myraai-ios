#!/usr/bin/env bash
# scripts/import_litellm_prices.sh
#
# Fetches LiteLLM's model_prices_and_context_window.json and upserts all
# known model prices into the gateway's config.db (model_price table).
#
# Usage:
#   ./scripts/import_litellm_prices.sh [/path/to/config.db] [/path/to/prices.json]
#
# If no DB path is given, defaults to data/config.db.
# If no JSON path is given, downloads from GitHub.
#
# Requires: python3, sqlite3, curl (only when downloading)

set -euo pipefail

DB="${1:-data/config.db}"
JSON_FILE="${2:-}"
LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

# LiteLLM provider name → our provider name
PROVIDER_MAP_PY='
PROVIDER_MAP = {
    "openai":                       "openai",
    "anthropic":                    "anthropic",
    "gemini":                       "gemini",
    "vertex_ai":                    "vertex",
    "vertex_ai-language-models":    "vertex",
    "bedrock":                      "bedrock",
    "cohere":                       "cohere",
    "mistral":                      "mistral",
    "groq":                         "groq",
    "together_ai":                  "together",
    "fireworks_ai":                 "fireworks",
    "deepseek":                     "deepseek",
    "xai":                          "xai",
    "perplexity":                   "perplexity",
    "openrouter":                   "openrouter",
    "ollama":                       "ollama",
    "ollama_chat":                  "ollama",
    "azure":                        "azure",
    "azure_ai":                     "azure",
    "huggingface":                  "huggingface",
    "cerebras":                     "cerebras",
    "nvidia_nim":                   "nvidia",
    "cloudflare":                   "cloudflare",
    "sambanova":                    "sambanova",
    "text-completion-openai":       "openai",
    "text-completion-codestral":    "mistral",
}
'

# ── fetch ────────────────────────────────────────────────────────────────────

if [[ -z "$JSON_FILE" ]]; then
    TMP_JSON=$(mktemp /tmp/litellm_prices.XXXXXX.json)
    trap 'rm -f "$TMP_JSON"' EXIT
    echo "Fetching $LITELLM_URL ..."
    curl -sSfL "$LITELLM_URL" -o "$TMP_JSON"
    JSON_FILE="$TMP_JSON"
fi

echo "Parsing $(wc -c < "$JSON_FILE") bytes from $JSON_FILE ..."

# ── transform → SQL, then apply ──────────────────────────────────────────────

TMP_SQL=$(mktemp /tmp/litellm_prices.XXXXXX.sql)
trap 'rm -f "${TMP_JSON:-}" "$TMP_SQL"' EXIT

python3 - "$JSON_FILE" "$TMP_SQL" <<PYEOF
import json, sys

${PROVIDER_MAP_PY}

with open(sys.argv[1]) as f:
    data = json.load(f)

rows = 0
lines = ["BEGIN;"]

for model_id, info in data.items():
    if not isinstance(info, dict):
        continue
    litellm_provider = info.get("litellm_provider", "")
    provider = PROVIDER_MAP.get(litellm_provider)
    if not provider:
        continue

    input_cost  = info.get("input_cost_per_token")
    output_cost = info.get("output_cost_per_token")
    if input_cost is None or output_cost is None:
        continue

    inp_1k = round(input_cost  * 1000, 10)
    out_1k = round(output_cost * 1000, 10)

    cache_write = info.get("cache_creation_input_token_cost")
    cache_read  = info.get("cache_read_input_token_cost")
    cw = str(round(cache_write * 1000, 10)) if cache_write is not None else "NULL"
    cr = str(round(cache_read  * 1000, 10)) if cache_read  is not None else "NULL"

    esc_model    = model_id.replace("'", "''")
    esc_provider = provider.replace("'", "''")
    now = "strftime('%Y-%m-%dT%H:%M:%fZ','now')"

    lines.append(
        f"INSERT OR REPLACE INTO model_price "
        f"(provider,model,input_per_1k,output_per_1k,cache_write_per_1k,cache_read_per_1k,updated_at) "
        f"VALUES ('{esc_provider}','{esc_model}',{inp_1k},{out_1k},{cw},{cr},{now});"
    )
    rows += 1

lines.append("COMMIT;")

with open(sys.argv[2], "w") as out:
    out.write("\n".join(lines))

print(f"Generated {rows} INSERT OR REPLACE statements.")
PYEOF

echo "Applying SQL to $DB ..."
sqlite3 "$DB" < "$TMP_SQL"
echo "Import complete."
