#!/usr/bin/env bash
# run_docker_integration.sh — start AI Gateway integration environment (Docker)
#
# Secrets are loaded from .env.integration (not committed to git).
# Run:  bash run_docker_integration.sh
set -euo pipefail

LOG=/tmp/run_docker_integration.log
: > "$LOG"
stage()     { echo "▶ $*"; }
done_next() { echo "✓ $1 — ▶ $2"; }
done_stage(){ echo "✓ $*"; }
log_cmd()   { "$@" >> "$LOG" 2>&1; }

exec 200>/tmp/ai-gateway-build.lock
flock 200

# ── Launch guard sentinel ────────────────────────────────────────────────────
export AIG_LAUNCHED_BY_SCRIPT=1

# ── Secrets (loaded from .env.integration) ───────────────────────────────────
stage "[1/4] Loading secrets"
ENV_FILE="$(dirname "$0")/.env.integration"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  echo "       Create it with AIG_MASTER_KEY_INT, AIG_JWT_SECRET_INT, AIG_MYSQL_PASS_INT, etc."
  exit 1
fi
set -a
# shellcheck source=.env.integration
source "$ENV_FILE"
set +a

# ── Build documentation ───────────────────────────────────────────────────────
done_next "Secrets loaded" "[2/4] Building documentation"
log_cmd bash -c "cd '$(dirname "$0")/docs' && bash gen_docs.sh"

# ── Build Android APK and copy to frontend/public ────────────────────────────
log_cmd bash -c "cd '$(dirname "$0")/src/mobile/android' && \
  ./gradlew assembleRelease && \
  cp app/build/outputs/apk/release/app-release.apk \
     '$(dirname "$0")/frontend/public/android.apk'"

# ── Build frontend with int URLs ──────────────────────────────────────────────
done_next "Documentation built" "[3/4] Building frontend"
log_cmd bash -c "cd '$(dirname "$0")/frontend' && \
  VITE_ADMIN_URL='https://ai-api-admin-int.myra.eu/admin/v1' \
  VITE_AUTH_URL='https://ai-api-admin-int.myra.eu/admin/auth' \
  VITE_GATEWAY_URL='https://ai-api-int.myra.eu' \
  VITE_DOCS_URL='https://ai-docs-int.myra.eu' \
  VITE_BUILD_DATE=\"$(date -u +"%Y-%m-%d %H:%M UTC") [INT]\" \
  npm run build"

# ── Run ───────────────────────────────────────────────────────────────────────
done_next "Frontend built" "[4/4] Building Docker image and starting int container"
docker compose -f "$(dirname "$0")/docker-compose.int.yml" up -d --build

# ── Connect shared Presidio sidecars to the int network ──────────────────────
# Presidio containers live on the production network; join them to int too so
# the int gateway can resolve http://presidio:3000 and http://presidio-anonymizer:3000.
INT_NETWORK="ai-gateway-int_default"
for container in aig-presidio-analyzer aig-presidio-anonymizer; do
  if docker inspect "$container" &>/dev/null; then
    alias="${container#aig-presidio-}"   # analyzer → analyzer, anonymizer → anonymizer
    # Map to the aliases the gateway config expects
    [[ "$container" == "aig-presidio-analyzer"   ]] && alias="presidio"
    [[ "$container" == "aig-presidio-anonymizer" ]] && alias="presidio-anonymizer"
    if docker network inspect "$INT_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "$container"; then
      echo "✓ $container already on $INT_NETWORK"
    else
      docker network connect --alias "$alias" "$INT_NETWORK" "$container"
      echo "✓ Connected $container to $INT_NETWORK (alias: $alias)"
    fi
  else
    echo "⚠ $container not running — PII features unavailable on int"
  fi
done
