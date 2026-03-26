#!/usr/bin/env bash
# build_frontend.sh — build the frontend with production env vars and hot-deploy to the running container.
# Usage: bash build_frontend.sh [container-name]
set -euo pipefail

CONTAINER="${1:-ai-gateway-gateway-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "==> Building frontend..."
cd "$ROOT/frontend"
VITE_ADMIN_URL="https://ai-api-admin.myra.eu/admin/v1" \
VITE_AUTH_URL="https://ai-api-admin.myra.eu/admin/auth" \
VITE_GATEWAY_URL="https://ai-api.myra.eu" \
VITE_DOCS_URL="https://ai-docs.myra.eu" \
npm run build

echo "==> Deploying to container '$CONTAINER'..."
# Wipe stale assets before copying so old hashed bundles don't accumulate.
docker exec "$CONTAINER" sh -c "rm -rf /opt/ai-gateway/frontend/assets /opt/ai-gateway/frontend/index.html"
docker cp dist/. "$CONTAINER":/opt/ai-gateway/frontend/

echo "==> Done."
