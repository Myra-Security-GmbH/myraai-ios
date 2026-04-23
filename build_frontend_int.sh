#!/usr/bin/env bash
# build_frontend_int.sh — build the frontend with int env vars and hot-deploy to the running int container.
# Usage: bash build_frontend_int.sh [container-name]
set -euo pipefail

CONTAINER="${1:-ai-gateway-int-gateway-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "==> Building frontend (int)..."
cd "$ROOT/frontend"
VITE_ADMIN_URL="https://ai-api-admin-int.myra.eu/admin/v1" \
VITE_AUTH_URL="https://ai-api-admin-int.myra.eu/admin/auth" \
VITE_GATEWAY_URL="https://ai-api-int.myra.eu" \
VITE_DOCS_URL="https://ai-docs-int.myra.eu" \
VITE_BUILD_DATE="$(date -u +"%Y-%m-%d %H:%M UTC") [INT]" \
npm run build

echo "==> Deploying to int container '$CONTAINER'..."
docker exec "$CONTAINER" sh -c "rm -rf /opt/ai-gateway/frontend/assets /opt/ai-gateway/frontend/index.html"
docker cp dist/. "$CONTAINER":/opt/ai-gateway/frontend/

echo "==> Done."
