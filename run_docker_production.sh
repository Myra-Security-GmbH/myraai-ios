#!/usr/bin/env bash
# run_docker_production.sh — start AI Gateway in production (Docker)
#
# Secrets are loaded from .env.production (not committed to git).
# Run:  bash run_docker_production.sh
set -euo pipefail

exec 200>/tmp/ai-gateway-run-docker.lock
flock -n 200 || { echo "run_docker_production.sh is already running"; exit 1; }

# ── Launch guard sentinel ────────────────────────────────────────────────────
export AIG_LAUNCHED_BY_SCRIPT=1

# ── Secrets (loaded from .env.production) ─────────────────────────────────────
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

# ── Build documentation ───────────────────────────────────────────────────────
(
  cd "$(dirname "$0")/docs"
  bash gen_docs.sh
  python3 gen_pdf.py
)

# ── Build frontend (uses private @myraui packages — must run on host) ─────────
(
  cd "$(dirname "$0")/frontend"
  VITE_ADMIN_URL="https://ai-api-admin.myra.eu/admin/v1" \
  VITE_AUTH_URL="https://ai-api-admin.myra.eu/admin/auth" \
  VITE_GATEWAY_URL="https://ai-api.myra.eu" \
  VITE_DOCS_URL="https://ai-docs.myra.eu" \
  npm run build
)

# ── Run ───────────────────────────────────────────────────────────────────────
exec docker compose up -d --build "$@"
