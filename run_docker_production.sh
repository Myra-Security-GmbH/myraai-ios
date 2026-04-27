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
stage()     { echo "▶ $*"; }
done_next() { echo "✓ $1 — ▶ $2"; }
done_stage(){ echo "✓ $*"; }
log_cmd()   { "$@" >> "$LOG" 2>&1; }

exec 200>/tmp/ai-gateway-build.lock
flock 200

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

# ── Build documentation ───────────────────────────────────────────────────────
done_next "Secrets loaded" "[2/5] Building documentation"
log_cmd bash -c "cd '$(dirname "$0")/docs' && bash gen_docs.sh"

# ── Generate PDF ─────────────────────────────────────────────────────────────
if [[ "$BUILD_PDF" == 1 ]]; then
  done_next "Documentation built" "[3/5] Generating PDF"
  log_cmd bash -c "cd '$(dirname "$0")/docs' && python3 gen_pdf.py"
  done_next "PDF generated" "[4/5] Building frontend"
else
  echo "✓ Documentation built — [3/5] PDF skipped — ▶ [4/5] Building frontend"
fi

# ── Build frontend (uses private @myraui packages — must run on host) ─────────
# ── Build Android APK first — copy to public so it's bundled into the image ──
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
log_cmd bash -c "cd '$REPO_ROOT/src/mobile/android' && \
  ./gradlew assembleRelease && \
  cp app/build/outputs/apk/release/app-release.apk \
     '$REPO_ROOT/frontend/public/android.apk'"
log_cmd bash -c "cd '$REPO_ROOT/frontend' && \
  VITE_ADMIN_URL='https://ai-api-admin.myra.eu/admin/v1' \
  VITE_AUTH_URL='https://ai-api-admin.myra.eu/admin/auth' \
  VITE_GATEWAY_URL='https://ai-api.myra.eu' \
  VITE_DOCS_URL='https://ai-docs.myra.eu' \
  VITE_BUILD_DATE=\"$(date -u +"%Y-%m-%d %H:%M UTC")\" \
  npm run build"

# ── Install systemd unit files ────────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$0")"
for svc in presidio; do
  src="$SCRIPT_DIR/config/${svc}.service"
  dst="/etc/systemd/system/${svc}.service"
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    echo "▶ Installing $dst"
    sudo cp "$src" "$dst"
    sudo systemctl daemon-reload
    sudo systemctl enable "${svc}.service"
  fi
done
done_stage "Systemd unit files up to date"

# ── Run ───────────────────────────────────────────────────────────────────────
done_next "Frontend built" "[5/5] Building Docker image and starting container"
exec docker compose up -d --build "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}"
