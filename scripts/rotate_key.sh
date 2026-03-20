#!/usr/bin/env bash
# scripts/rotate_key.sh — update a provider API key for an existing gateway
#
# Usage:
#   ./scripts/rotate_key.sh --tenant my-company --gateway prod
#   ./scripts/rotate_key.sh --tenant my-company --gateway prod --provider openai
#
# The new key is read from the matching env var (ANTHROPIC_API_KEY, OPENAI_API_KEY,
# GEMINI_API_KEY) or passed directly with --key sk-ant-...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export AIG_CONFIG="${AIG_CONFIG:-$REPO_ROOT/config/gateway.lua}"

if [[ -z "${AIG_MASTER_KEY:-}" ]]; then
    echo "Note: AIG_MASTER_KEY is not set — using default dev key" >&2
    unset AIG_MASTER_KEY
else
    export AIG_MASTER_KEY
fi

exec resty \
    -I "$REPO_ROOT/src" \
    -e "package.cpath = package.cpath .. ';/usr/lib/x86_64-linux-gnu/lua/5.1/?.so'" \
    "$SCRIPT_DIR/rotate_key.lua" \
    "$@"
