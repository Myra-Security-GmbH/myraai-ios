#!/usr/bin/env bash
# run-e2e.sh — Exclusive lock wrapper for Playwright.
# Prevents two E2E runs colliding on shared Docker/MySQL state.
#
# Default (no --config flag): runs the full suite in two passes:
#   1. Parallel pass  — playwright.docker.config.ts (workers:16, safe files)
#   2. Sequential pass — playwright.docker.sequential.config.ts (workers:1,
#      files that use deleteAllConversations and would cross-contaminate)
#
# Single-config usage (bypass the two-pass logic):
#   ./run-e2e.sh --config playwright.docker.config.ts [args...]
#   ./run-e2e.sh --config playwright.docker.sequential.config.ts [args...]
#   ./run-e2e.sh --config playwright.production.config.ts [args...]
#
# Grep / file filter still works in two-pass mode — both passes receive the
# same extra arguments so only matching tests run in each pass.
#
# If another run is already in progress, exits immediately with an error.

set -euo pipefail

LOCK_FILE="/tmp/ai-gateway-playwright.lock"
PID_FILE="/tmp/ai-gateway-playwright.pid"
LOCK_FD=9

# Open the lock file on fd 9 (exclusive advisory lock)
exec 9>"$LOCK_FILE"

if ! flock -n $LOCK_FD; then
  HOLDER=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
  echo "ERROR: Another Playwright run is already in progress (PID $HOLDER)." >&2
  echo "       Lock file: $LOCK_FILE" >&2
  echo "       Wait for it to finish, or remove the lock file if the process is gone." >&2
  exit 1
fi

# Record our PID; clean it up on any exit
echo $$ >"$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

cd "$(dirname "$0")"

# Check if a --config flag was provided.  If so, pass everything straight to
# Playwright (single-config mode) — no two-pass logic.
for arg in "$@"; do
  if [[ "$arg" == "--config" ]]; then
    # When running against the int environment, pass DB credentials for workers.setup.ts.
    if [[ "$*" == *"playwright.int.config"* ]] && [[ -f "$(dirname "$0")/../.env.integration" ]]; then
      set -a
      # shellcheck source=../.env.integration
      source "$(dirname "$0")/../.env.integration"
      set +a
      export E2E_DB_USER="${AIG_MYSQL_USER:-gateway_int}"
      export E2E_DB_PASS="${AIG_MYSQL_PASS_INT:-}"
      export E2E_DB_NAME="${AIG_MYSQL_DB:-ai_gateway_int}"
    elif [[ "$*" == *"playwright.config"* ]] && ! [[ "$*" == *"playwright.docker"* || "$*" == *"playwright.int"* || "$*" == *"playwright.production"* ]]; then
      # Dev config — uses gateway_dev
      export E2E_DB_USER="${E2E_DB_USER:-gateway}"
      export E2E_DB_PASS="${E2E_DB_PASS:-gateway}"
      export E2E_DB_NAME="${E2E_DB_NAME:-gateway_dev}"
    fi
    exec npx playwright test "$@"
  fi
done

# Two-pass mode: parallel-safe files first, then sequential files.
EXIT_CODE=0

echo "==> Pass 1: parallel (workers:16)"
npx playwright test --config playwright.docker.config.ts --max-failures=5 "$@" || EXIT_CODE=$?

echo "==> Pass 2: sequential (workers:1)"
# --pass-with-no-tests: exit 0 when no files match (e.g. only safe files were requested)
npx playwright test --config playwright.docker.sequential.config.ts --pass-with-no-tests --max-failures=5 "$@" || EXIT_CODE=$?

exit $EXIT_CODE
