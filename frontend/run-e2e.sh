#!/usr/bin/env bash
# run-e2e.sh — Exclusive lock wrapper for Playwright.
# Prevents two E2E runs colliding on shared Docker/MySQL state.
#
# Usage (drop-in replacement for npx playwright test):
#   ./run-e2e.sh [--config playwright.docker.config.ts] [...playwright args]
#
# If another run is already in progress, exits immediately with an error.

set -euo pipefail

LOCK_FILE="/tmp/ai-gateway-playwright.lock"
PID_FILE="/tmp/ai-gateway-playwright.pid"
LOCK_FD=9

# Open the lock file on fd 9 (exclusive advisory lock — does not affect content of PID_FILE)
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

# Run Playwright with all forwarded arguments; lock is released automatically on exit
cd "$(dirname "$0")"
exec npx playwright test "$@"
