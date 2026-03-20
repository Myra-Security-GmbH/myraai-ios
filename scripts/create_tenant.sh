#!/usr/bin/env bash
# scripts/create_tenant.sh — interactive tenant setup for AI Gateway
#
# Usage:
#   ./scripts/create_tenant.sh [--tenant NAME] [--gateway NAME] [--budget USD] [--no-auth]
#
# Required env (at least one provider key):
#   ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY
#
# Optional env:
#   AIG_CONFIG      — path to gateway.lua  (default: config/gateway.lua)
#   AIG_MASTER_KEY  — encryption key        (default: dev key, warn if not set)
#   AIG_DATA_DIR    — SQLite directory      (default: data/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TENANT="my-tenant"
GATEWAY="default"
BUDGET=""
NO_AUTH=""

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant)   TENANT="$2";  shift 2 ;;
        --gateway)  GATEWAY="$2"; shift 2 ;;
        --budget)   BUDGET="$2";  shift 2 ;;
        --no-auth)  NO_AUTH="--no-auth"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export AIG_CONFIG="${AIG_CONFIG:-$REPO_ROOT/config/gateway.lua}"
export AIG_DATA_DIR="${AIG_DATA_DIR:-$REPO_ROOT/data}"

if [[ -z "${AIG_MASTER_KEY:-}" ]]; then
    echo "WARNING: AIG_MASTER_KEY is not set — using insecure dev key." >&2
    echo "         Set AIG_MASTER_KEY in production." >&2
fi

# Check at least one provider key is set
PROVIDER_KEYS=(ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GROQ_API_KEY MISTRAL_API_KEY)
FOUND_KEY=0
for VAR in "${PROVIDER_KEYS[@]}"; do
    if [[ -n "${!VAR:-}" ]]; then
        FOUND_KEY=1
        break
    fi
done

if [[ $FOUND_KEY -eq 0 ]]; then
    echo "ERROR: No provider API key found in environment." >&2
    echo "       Set at least one of: ${PROVIDER_KEYS[*]}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure data directory exists
# ---------------------------------------------------------------------------
mkdir -p "$AIG_DATA_DIR"

# ---------------------------------------------------------------------------
# Build resty args
# ---------------------------------------------------------------------------
RESTY_ARGS=(
    -I "$REPO_ROOT/src"
    -e "package.cpath = package.cpath .. ';/usr/lib/x86_64-linux-gnu/lua/5.1/?.so'"
    "$SCRIPT_DIR/setup_tenant.lua"
    --tenant "$TENANT"
    --gateway "$GATEWAY"
)
[[ -n "$BUDGET"  ]] && RESTY_ARGS+=(--budget "$BUDGET")
[[ -n "$NO_AUTH" ]] && RESTY_ARGS+=(--no-auth)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
echo "Setting up tenant '$TENANT' / gateway '$GATEWAY'..."
echo ""

resty "${RESTY_ARGS[@]}"

echo ""
echo "To apply, reload OpenResty:"
echo "  sudo openresty -s reload"
