#!/usr/bin/env bash
# run_docker_production.sh — start AI Gateway in production (Docker)
#
# Secrets are loaded from .env.production (not committed to git).
# Run:  bash run_docker_production.sh [--pdf]
#   --pdf   also regenerate the PDF (slow; skipped by default)
set -euo pipefail

BUILD_PDF=0
DOCKER_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--pdf" ]]; then BUILD_PDF=1
  else DOCKER_ARGS+=("$arg"); fi
done

LOG=/tmp/run_docker_production.log
: > "$LOG"
stage() { echo ""; echo "▶ $*"; }
done_stage() { echo "✓ $*"; }
log_cmd() { "$@" >> "$LOG" 2>&1; }

exec 200>/tmp/ai-gateway-run-docker.lock
flock -n 200 || { echo "run_docker_production.sh is already running"; exit 1; }

# ── Launch guard sentinel ────────────────────────────────────────────────────
export AIG_LAUNCHED_BY_SCRIPT=1

# ── Secrets (loaded from .env.production) ─────────────────────────────────────
stage "[1/5] Loading secrets"
ENV_FILE="$(dirname "$0")/.env.production"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  echo "       Copy .env.production.example and fill in the secrets."
  exit 1
fi
set -a
# shellcheck source=.env.production
source "$ENV_FILE"
set +a
done_stage "[1/5] Secrets loaded"

# ── Build documentation ───────────────────────────────────────────────────────
stage "[2/5] Building documentation"
log_cmd bash -c "cd '$(dirname "$0")/docs' && bash gen_docs.sh"
done_stage "[2/5] Documentation built"

# ── Generate PDF ─────────────────────────────────────────────────────────────
if [[ "$BUILD_PDF" == 1 ]]; then
  stage "[3/5] Generating PDF"
  log_cmd bash -c "cd '$(dirname "$0")/docs' && python3 gen_pdf.py"
  done_stage "[3/5] PDF generated"
else
  stage "[3/5] Skipping PDF (pass --pdf to generate)"
fi

# ── Build frontend (uses private @myraui packages — must run on host) ─────────
stage "[4/5] Building frontend"
log_cmd bash -c "cd '$(dirname "$0")/frontend' && \
  VITE_ADMIN_URL='https://ai-api-admin.myra.eu/admin/v1' \
  VITE_AUTH_URL='https://ai-api-admin.myra.eu/admin/auth' \
  VITE_GATEWAY_URL='https://ai-api.myra.eu' \
  VITE_DOCS_URL='https://ai-docs.myra.eu' \
  npm run build"
done_stage "[4/5] Frontend built"

# ── Run ───────────────────────────────────────────────────────────────────────
stage "[5/5] Building Docker image and starting container"
exec docker compose up -d --build "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}"
