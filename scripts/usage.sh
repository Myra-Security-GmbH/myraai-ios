#!/usr/bin/env bash
# scripts/usage.sh — show token and cost usage per tenant/gateway
#
# Usage:
#   ./scripts/usage.sh                        # all tenants, all time
#   ./scripts/usage.sh --tenant acme          # one tenant
#   ./scripts/usage.sh --days 7               # last 7 days
#   ./scripts/usage.sh --by model             # break down by model
#   ./scripts/usage.sh --by provider          # break down by provider
#   ./scripts/usage.sh --requests             # show individual requests (tail 50)
#   ./scripts/usage.sh --tenant acme --days 1 --by model

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/config.db"
LOGS_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/logs.db"

TENANT_FILTER=""
DAYS_FILTER=""
BREAK_BY=""
SHOW_REQUESTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant)   TENANT_FILTER="$2"; shift 2 ;;
        --days)     DAYS_FILTER="$2";   shift 2 ;;
        --by)       BREAK_BY="$2";      shift 2 ;;
        --requests) SHOW_REQUESTS=1;    shift   ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$LOGS_DB" ]]; then
    echo "No logs database found at $LOGS_DB"
    echo "Run some requests first."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build WHERE clause fragments
# ---------------------------------------------------------------------------
TENANT_JOIN=""
TENANT_COND=""
if [[ -n "$TENANT_FILTER" ]]; then
    TENANT_JOIN="JOIN (SELECT id FROM tenants WHERE slug = '$TENANT_FILTER') t ON l.tenant_id = t.id"
    TENANT_COND="AND l.tenant_id = (SELECT id FROM tenants WHERE slug = '$TENANT_FILTER')"
fi

DAYS_COND=""
if [[ -n "$DAYS_FILTER" ]]; then
    DAYS_COND="AND l.ts >= datetime('now', '-${DAYS_FILTER} days')"
fi

WHERE="WHERE 1=1 $TENANT_COND $DAYS_COND"

# ---------------------------------------------------------------------------
# Helper: run a query against both DBs (ATTACH config.db for tenant names)
# ---------------------------------------------------------------------------
run_sql() {
    sqlite3 -column -header "$LOGS_DB" \
        "ATTACH DATABASE '$CONFIG_DB' AS cfg; $1"
}

# ---------------------------------------------------------------------------
# Summary by tenant + gateway
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
if [[ -n "$DAYS_FILTER" ]]; then
    echo " Usage — last ${DAYS_FILTER} day(s)"
else
    echo " Usage — all time"
fi
[[ -n "$TENANT_FILTER" ]] && echo " Tenant: $TENANT_FILTER"
echo "========================================"
echo ""

run_sql "
SELECT
    COALESCE(t.slug, l.tenant_id) AS tenant,
    COALESCE(g.slug, l.gateway_id) AS gateway,
    COUNT(*)                        AS requests,
    SUM(CASE WHEN l.cached=1 THEN 1 ELSE 0 END) AS cached,
    SUM(l.input_tokens)             AS input_tok,
    SUM(l.output_tokens)            AS output_tok,
    ROUND(SUM(l.cost_usd), 4)       AS cost_usd,
    ROUND(AVG(l.latency_ms))        AS avg_ms
FROM main.request_logs l
LEFT JOIN cfg.tenants  t ON t.id = l.tenant_id
LEFT JOIN cfg.gateways g ON g.id = l.gateway_id
$WHERE
GROUP BY l.tenant_id, l.gateway_id
ORDER BY cost_usd DESC;
"

# ---------------------------------------------------------------------------
# Optional breakdown
# ---------------------------------------------------------------------------
if [[ -n "$BREAK_BY" ]]; then
    echo ""
    echo "--- By $BREAK_BY ---"
    echo ""

    case "$BREAK_BY" in
        model)
            run_sql "
SELECT
    COALESCE(t.slug, l.tenant_id) AS tenant,
    l.model,
    COUNT(*)                       AS requests,
    SUM(l.input_tokens)            AS input_tok,
    SUM(l.output_tokens)           AS output_tok,
    ROUND(SUM(l.cost_usd), 4)      AS cost_usd
FROM main.request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
$WHERE
GROUP BY l.tenant_id, l.model
ORDER BY cost_usd DESC;
"
            ;;
        provider)
            run_sql "
SELECT
    COALESCE(t.slug, l.tenant_id) AS tenant,
    l.provider,
    COUNT(*)                       AS requests,
    SUM(l.input_tokens)            AS input_tok,
    SUM(l.output_tokens)           AS output_tok,
    ROUND(SUM(l.cost_usd), 4)      AS cost_usd
FROM main.request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
$WHERE
GROUP BY l.tenant_id, l.provider
ORDER BY cost_usd DESC;
"
            ;;
        day)
            run_sql "
SELECT
    COALESCE(t.slug, l.tenant_id)  AS tenant,
    substr(l.ts, 1, 10)            AS date,
    COUNT(*)                        AS requests,
    SUM(l.input_tokens)             AS input_tok,
    SUM(l.output_tokens)            AS output_tok,
    ROUND(SUM(l.cost_usd), 4)       AS cost_usd
FROM main.request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
$WHERE
GROUP BY l.tenant_id, date
ORDER BY tenant, date DESC;
"
            ;;
        *)
            echo "Unknown --by value: $BREAK_BY  (use: model | provider | day)" >&2
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Individual requests (last 50)
# ---------------------------------------------------------------------------
if [[ $SHOW_REQUESTS -eq 1 ]]; then
    echo ""
    echo "--- Last 50 requests ---"
    echo ""
    run_sql "
SELECT
    substr(l.ts,1,19)              AS time,
    COALESCE(t.slug, l.tenant_id) AS tenant,
    l.provider,
    l.model,
    l.status,
    l.input_tokens                 AS in_tok,
    l.output_tokens                AS out_tok,
    ROUND(l.cost_usd, 5)           AS cost_usd,
    l.latency_ms                   AS ms,
    CASE WHEN l.cached=1 THEN 'Y' ELSE '' END AS cache
FROM main.request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
$WHERE
ORDER BY l.ts DESC
LIMIT 50;
"
fi

echo ""
