#!/usr/bin/env bash
# create_snapshot.sh — capture admin UI screenshots and embed them in the docs.
#
# Usage:
#   bash create_snapshot.sh [--host HOST:PORT]
#
# Prerequisites:
#   • The admin UI dev server must be running on the target host (default
#     localhost:5173).  Start it with:  cd frontend && npm run dev
#   • Playwright browsers must be installed:  cd frontend && npx playwright install chromium
#
# What this script does:
#   1. Checks that the dev server is reachable.
#   2. Creates docs/docs.md/assets/screenshots/ if it does not exist.
#   3. Runs frontend/tests/screenshots.spec.ts via Playwright (Chromium).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND="$SCRIPT_DIR/frontend"
SCREENSHOTS_DIR="$SCRIPT_DIR/docs/docs.md/assets/screenshots"
HOST="localhost:5173"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --host=*)
      HOST="${1#--host=}"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--host HOST:PORT]" >&2
      exit 1
      ;;
  esac
done

# ── Step 1: verify dev server is up ──────────────────────────────────────────
echo "→ Checking dev server at http://$HOST ..."
if ! curl -sf --max-time 5 "http://$HOST" > /dev/null 2>&1; then
  echo ""
  echo "ERROR: Admin UI dev server not reachable at http://$HOST"
  echo ""
  echo "Start it first:"
  echo "  cd frontend && npm run dev"
  echo ""
  echo "Then re-run this script."
  exit 1
fi
echo "  ✓ Dev server is up."

# ── Step 2: create output directory ──────────────────────────────────────────
mkdir -p "$SCREENSHOTS_DIR"
echo "→ Output directory: $SCREENSHOTS_DIR"

# ── Step 3: run Playwright screenshot spec ───────────────────────────────────
echo "→ Running screenshot spec ..."
cd "$FRONTEND"

# Override baseURL if a non-default host was supplied
PLAYWRIGHT_ARGS=(
  "tests/screenshots.spec.ts"
  "--project=chromium"
  "--reporter=list"
)
if [[ "$HOST" != "localhost:5173" ]]; then
  PLAYWRIGHT_ARGS+=("--config=/dev/stdin")
  # Pipe a minimal config override so baseURL picks up the custom host
  npx playwright test "${PLAYWRIGHT_ARGS[@]}" \
    < <(echo "
      const { defineConfig } = require('@playwright/test');
      module.exports = defineConfig({ use: { baseURL: 'http://$HOST' } });
    ")
else
  npx playwright test "${PLAYWRIGHT_ARGS[@]}"
fi

echo ""
echo "✓ Done. Screenshots saved to:"
ls "$SCREENSHOTS_DIR"/*.png 2>/dev/null | sed 's|^|    |' || echo "    (none — check Playwright output above)"
