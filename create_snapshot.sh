#!/usr/bin/env bash
# create_snapshot.sh — capture admin UI screenshots and embed them in the docs.
#
# Usage (local dev server):
#   bash create_snapshot.sh [--host HOST:PORT]
#
# Usage (live Docker stack — uses saved docker session for auth):
#   bash create_snapshot.sh --docker
#
# Prerequisites (local mode):
#   • The admin UI dev server must be running on the target host (default
#     localhost:5173).  Start it with:  cd frontend && npm run dev
#   • Playwright browsers must be installed:  cd frontend && npx playwright install chromium
#
# Prerequisites (docker mode):
#   • The Docker stack must be running and reachable at https://ai.myra.eu
#   • A valid session must exist at frontend/tests/.auth/docker-session.json
#     (run: cd frontend && npx playwright test --config playwright.docker.config.ts
#      --project docker-setup  to create one)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND="$SCRIPT_DIR/frontend"
SCREENSHOTS_DIR="$SCRIPT_DIR/docs/docs.md/assets/screenshots"
HOST="localhost:5173"
DOCKER_MODE=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --docker)
      DOCKER_MODE=true
      shift
      ;;
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
      echo "Usage: $0 [--host HOST:PORT] | [--docker]" >&2
      exit 1
      ;;
  esac
done

# ── Create output directory ───────────────────────────────────────────────────
mkdir -p "$SCREENSHOTS_DIR"
echo "→ Output directory: $SCREENSHOTS_DIR"

# ── Run Playwright screenshot spec ───────────────────────────────────────────
cd "$FRONTEND"

if [[ "$DOCKER_MODE" == true ]]; then
  SESSION="$FRONTEND/tests/.auth/docker-session.json"
  if [[ ! -f "$SESSION" ]]; then
    echo ""
    echo "ERROR: No docker session found at $SESSION"
    echo ""
    echo "Create one first:"
    echo "  cd frontend && npx playwright test --config playwright.docker.config.ts --project docker-setup"
    echo ""
    exit 1
  fi
  echo "→ Docker mode — targeting https://ai.myra.eu (session: $SESSION)"
  echo "→ Running screenshot spec ..."
  npx playwright test tests/screenshots.spec.ts \
    --config playwright.docker.config.ts \
    --project screenshots \
    --no-deps \
    --reporter=list
else
  # ── Verify dev server is up ─────────────────────────────────────────────────
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
  echo "→ Running screenshot spec ..."

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
fi

echo ""
echo "✓ Done. Screenshots saved to:"
ls "$SCREENSHOTS_DIR"/*.png 2>/dev/null | sed 's|^|    |' || echo "    (none — check Playwright output above)"
