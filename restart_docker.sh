#!/usr/bin/env bash
# restart_docker.sh — restart AI Gateway container without rebuilding
set -euo pipefail

export AIG_LAUNCHED_BY_SCRIPT=1

ENV_FILE="$(dirname "$0")/.env.production"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

exec docker compose -f "$(dirname "$0")/docker-compose.yml" up -d "$@"
