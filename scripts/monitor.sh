#!/usr/bin/env bash
# scripts/monitor.sh — terminal real-time monitor for AI Gateway
#
# Usage:
#   ./scripts/monitor.sh              # refresh every 2s
#   ./scripts/monitor.sh --interval 5 # refresh every 5s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOGS_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/logs.db"
CFG_DB="${AIG_DATA_DIR:-$REPO_ROOT/data}/config.db"
INTERVAL=2
GW_URL="${AIG_GATEWAY_URL:-http://127.0.0.1:8081}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$LOGS_DB" ]]; then
    echo "No logs.db at $LOGS_DB — run some requests first."
    exit 1
fi

sql() {
    sqlite3 "$LOGS_DB" \
        "ATTACH DATABASE '$CFG_DB' AS cfg; $1" 2>/dev/null
}

render() {
    clear
    local now
    now=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║  AI Gateway Monitor                    %s  ║\n" "$now"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # ── Last minute ─────────────────────────────────────────────────
    echo "  ── Last 60 seconds ────────────────────────────────────────"
    sql "
SELECT
  COUNT(*)                           AS requests,
  COALESCE(SUM(input_tokens),0)      AS in_tok,
  COALESCE(SUM(output_tokens),0)     AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),6) AS cost,
  ROUND(COALESCE(AVG(latency_ms),0)) AS avg_ms
FROM request_logs
WHERE ts >= datetime('now','-1 minute')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  In: %-8s  Out: %-8s  Cost: $%-10s  Avg: %sms\n",
           $1,$2,$3,$4,$5
}'
    echo ""

    # ── Last hour ────────────────────────────────────────────────────
    echo "  ── Last hour ───────────────────────────────────────────────"
    sql "
SELECT
  COUNT(*)                           AS requests,
  SUM(CASE WHEN cached=1 THEN 1 ELSE 0 END) AS cached,
  COALESCE(SUM(input_tokens),0)      AS in_tok,
  COALESCE(SUM(output_tokens),0)     AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),4) AS cost,
  ROUND(COALESCE(AVG(latency_ms),0)) AS avg_ms
FROM request_logs
WHERE ts >= datetime('now','-1 hour')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  Cached: %-5s  In: %-8s  Out: %-8s  Cost: $%-10s  Avg: %sms\n",
           $1,$2,$3,$4,$5,$6
}'
    echo ""

    # ── Today ────────────────────────────────────────────────────────
    echo "  ── Today (UTC) ─────────────────────────────────────────────"
    sql "
SELECT
  COUNT(*)                           AS requests,
  SUM(CASE WHEN cached=1 THEN 1 ELSE 0 END) AS cached,
  COALESCE(SUM(input_tokens),0)      AS in_tok,
  COALESCE(SUM(output_tokens),0)     AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),4) AS cost,
  ROUND(COALESCE(AVG(latency_ms),0)) AS avg_ms
FROM request_logs
WHERE ts >= strftime('%Y-%m-%dT00:00:00Z','now')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  Cached: %-5s  In: %-8s  Out: %-8s  Cost: $%-10s  Avg: %sms\n",
           $1,$2,$3,$4,$5,$6
}'
    echo ""

    # ── Per tenant today ─────────────────────────────────────────────
    echo "  ── Tenants today ───────────────────────────────────────────"
    printf "  %-20s  %8s  %10s  %10s  %10s\n" "TENANT" "REQUESTS" "IN TOK" "OUT TOK" "COST USD"
    printf "  %-20s  %8s  %10s  %10s  %10s\n" "--------------------" "--------" "----------" "----------" "--------"
    sql "
SELECT
  COALESCE(t.slug, l.tenant_id)     AS tenant,
  COUNT(*)                           AS requests,
  COALESCE(SUM(l.input_tokens),0)   AS in_tok,
  COALESCE(SUM(l.output_tokens),0)  AS out_tok,
  ROUND(COALESCE(SUM(l.cost_usd),0),4) AS cost
FROM request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
WHERE l.ts >= strftime('%Y-%m-%dT00:00:00Z','now')
GROUP BY l.tenant_id
ORDER BY cost DESC
LIMIT 10
" | awk -F'|' '{
    printf "  %-20s  %8s  %10s  %10s  $%-9s\n", $1,$2,$3,$4,$5
}'
    echo ""

    # ── Recent requests ───────────────────────────────────────────────
    echo "  ── Last 10 requests ────────────────────────────────────────"
    printf "  %-19s  %-12s  %-10s  %-24s  %3s  %6s  %6s  %9s  %5s\n" \
        "TIME" "TENANT" "PROVIDER" "MODEL" "ST" "IN" "OUT" "COST" "MS"
    printf "  %-19s  %-12s  %-10s  %-24s  %3s  %6s  %6s  %9s  %5s\n" \
        "-------------------" "------------" "----------" "------------------------" "---" "------" "------" "---------" "-----"
    sql "
SELECT
  substr(l.ts,1,19)                  AS ts,
  COALESCE(t.slug, substr(l.tenant_id,1,8)) AS tenant,
  l.provider,
  substr(l.model,1,24)               AS model,
  l.status,
  l.input_tokens,
  l.output_tokens,
  ROUND(l.cost_usd,5)                AS cost,
  l.latency_ms,
  l.cached
FROM request_logs l
LEFT JOIN cfg.tenants t ON t.id = l.tenant_id
ORDER BY l.ts DESC LIMIT 10
" | awk -F'|' '{
    cached = ($10 == "1") ? " C" : "  "
    printf "  %-19s  %-12s  %-10s  %-24s  %3s%s  %6s  %6s  $%-8s  %5s\n",
           $1,$2,$3,$4,$5,cached,$6,$7,$8,$9
}'

    echo ""
    echo "  Refreshing every ${INTERVAL}s — Ctrl+C to exit"
    echo "  Web dashboard: ${GW_URL}/monitor"
}

# Run once immediately, then loop
while true; do
    render
    sleep "$INTERVAL"
done
