# ── Final image ───────────────────────────────────────────────────────────────
# Frontend must be pre-built on the host before docker build:
#   cd frontend && VITE_ADMIN_URL=https://ai-api-admin.myra.eu/admin/v1 \
#                  VITE_AUTH_URL=https://ai-api-admin.myra.eu/admin/auth \
#                  VITE_GATEWAY_URL=https://ai-api.myra.eu \
#                  npm run build
FROM openresty/openresty:bullseye

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        msmtp \
        msmtp-mta \
        openresty-resty \
        python3 \
        python3-pip \
        pandoc \
        fonts-liberation \
        libpango-1.0-0 \
        libpangocairo-1.0-0 \
        libcairo2 \
        libgdk-pixbuf2.0-0 \
    && pip3 install --no-cache-dir weasyprint \
    && rm -rf /var/lib/apt/lists/*

# Lua vendor dependencies (lua-resty-http, lua-resty-hmac)
COPY vendor/resty/ /usr/local/openresty/lualib/resty/

# Lua source (no build step — interpreted at runtime)
COPY src/        /opt/ai-gateway/src/
COPY templates/  /opt/ai-gateway/templates/
COPY config/gateway.docker.lua    /opt/ai-gateway/config/gateway.lua
COPY config/nginx.docker.conf     /etc/openresty/nginx.conf
COPY config/docker-entrypoint.sh  /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# React frontend (pre-built on host — see comment at top of file)
COPY frontend/dist/ /opt/ai-gateway/frontend/

# Documentation (pre-built: run `cd docs && mkdocs build` before docker build)
COPY docs/out/ /opt/ai-gateway/docs/

# SQLite data directory — mount a volume here for persistence
RUN mkdir -p /data && chown nobody:nogroup /data

ENV AIG_CONFIG=/opt/ai-gateway/config/gateway.lua
ENV AIG_DATA_DIR=/data

EXPOSE 443

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s \
    CMD curl -sfk https://127.0.0.1/healthz -H "Host: ai-api.myra.eu" || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["openresty", "-g", "daemon off;"]
