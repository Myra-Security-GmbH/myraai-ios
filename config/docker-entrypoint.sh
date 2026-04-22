#!/bin/sh
# docker-entrypoint.sh — validate required env vars, write msmtp config, start openresty.
# Required env vars: AIG_MASTER_KEY, AIG_JWT_SECRET
# Required when AIG_STORAGE=mysql: AIG_MYSQL_PASS
# Optional SMTP:    AIG_SMTP_HOST, AIG_SMTP_USER, AIG_SMTP_PASS
#                   AIG_SMTP_PORT (default 25), AIG_SMTP_FROM (default AIG_OTP_FROM_EMAIL)

set -e

# ── Launch guard ───────────────────────────────────────────────────────────────
if [ "${AIG_LAUNCHED_BY_SCRIPT:-}" != "1" ]; then
    echo "ERROR: start the container via run_docker_production.sh, not directly." >&2
    echo "       run_docker_production.sh sets required secrets and AIG_LAUNCHED_BY_SCRIPT=1." >&2
    exit 1
fi

# ── Required env var validation ────────────────────────────────────────────────
_fail=0

_require() {
    _var="$1"
    _forbidden="$2"
    eval "_val=\$$_var"
    if [ -z "$_val" ]; then
        echo "ERROR: required environment variable $_var is not set" >&2
        _fail=1
    elif [ -n "$_forbidden" ] && [ "$_val" = "$_forbidden" ]; then
        echo "ERROR: $_var is still set to the insecure default '$_forbidden' — change it" >&2
        _fail=1
    fi
}

_require AIG_MASTER_KEY  "dev-insecure-key-change-in-prod-!!"
_require AIG_JWT_SECRET  "dev-change-me"

if [ "${AIG_STORAGE:-sqlite}" = "mysql" ]; then
    _require AIG_MYSQL_PASS ""
    _require AIG_MYSQL_USER ""
    _require AIG_MYSQL_DB   ""
fi

if [ "$_fail" = "1" ]; then
    echo "Aborting: fix the environment variables listed above before starting the container." >&2
    exit 1
fi

SMTP_HOST="${AIG_SMTP_HOST:-}"
SMTP_PORT="${AIG_SMTP_PORT:-25}"
SMTP_USER="${AIG_SMTP_USER:-}"
SMTP_PASS="${AIG_SMTP_PASS:-}"
SMTP_FROM="${AIG_SMTP_FROM:-${AIG_OTP_FROM_EMAIL:-noreply@localhost}}"

if [ -n "$SMTP_HOST" ]; then
    cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   on
tls_certcheck  off
logfile        /proc/1/fd/2

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${SMTP_FROM}
user           ${SMTP_USER}
password       ${SMTP_PASS}
EOF
    chmod 644 /etc/msmtprc

    # Verify TCP connectivity to the SMTP relay so failures are visible at startup.
    if curl -sf --max-time 5 "smtp://${SMTP_HOST}:${SMTP_PORT}" -o /dev/null 2>/dev/null; then
        echo "SMTP: relay ${SMTP_HOST}:${SMTP_PORT} reachable" >&2
    else
        echo "WARNING: cannot reach SMTP relay ${SMTP_HOST}:${SMTP_PORT} — OTP email delivery will fail" >&2
    fi
else
    # No SMTP configured — write a no-op config so sendmail doesn't crash.
    cat > /etc/msmtprc <<EOF
defaults
logfile /proc/1/fd/2

account default
host    127.0.0.1
port    25
from    ${SMTP_FROM}
EOF
fi

exec "$@"
