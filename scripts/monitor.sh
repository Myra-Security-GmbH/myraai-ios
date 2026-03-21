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
  COUNT(*)                                    AS requests,
  SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
  COALESCE(SUM(input_tokens),0)               AS in_tok,
  COALESCE(SUM(output_tokens),0)              AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),6)          AS cost,
  ROUND(COALESCE(SUM(saved_cost_usd),0),6)    AS saved,
  ROUND(COALESCE(AVG(latency_ms),0))          AS avg_ms,
  ROUND(COALESCE(AVG(upstream_latency_ms),0)) AS prov_ms
FROM request_log
WHERE ts >= datetime('now','-1 minute')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  Blocked: %-5s  In: %-8s  Out: %-8s  Cost: $%-8s  Saved: $%-8s  Avg: %sms  Prov: %sms\n",
           $1,$2,$3,$4,$5,$6,$7,$8
}'
    echo ""

    # ── Last hour ────────────────────────────────────────────────────
    echo "  ── Last hour ───────────────────────────────────────────────"
    sql "
SELECT
  COUNT(*)                                    AS requests,
  SUM(CASE WHEN cached=1  THEN 1 ELSE 0 END) AS cached,
  SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
  COALESCE(SUM(input_tokens),0)               AS in_tok,
  COALESCE(SUM(output_tokens),0)              AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),4)          AS cost,
  ROUND(COALESCE(SUM(saved_cost_usd),0),4)    AS saved,
  ROUND(COALESCE(AVG(latency_ms),0))          AS avg_ms,
  ROUND(COALESCE(AVG(upstream_latency_ms),0)) AS prov_ms
FROM request_log
WHERE ts >= datetime('now','-1 hour')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  Cached: %-5s  Blocked: %-5s  In: %-8s  Out: %-8s  Cost: $%-8s  Saved: $%-8s  Avg: %sms  Prov: %sms\n",
           $1,$2,$3,$4,$5,$6,$7,$8,$9
}'
    echo ""

    # ── Today ────────────────────────────────────────────────────────
    echo "  ── Today (UTC) ─────────────────────────────────────────────"
    sql "
SELECT
  COUNT(*)                                    AS requests,
  SUM(CASE WHEN cached=1  THEN 1 ELSE 0 END) AS cached,
  SUM(CASE WHEN blocked=1 THEN 1 ELSE 0 END) AS blocked,
  COALESCE(SUM(input_tokens),0)               AS in_tok,
  COALESCE(SUM(output_tokens),0)              AS out_tok,
  ROUND(COALESCE(SUM(cost_usd),0),4)          AS cost,
  ROUND(COALESCE(SUM(saved_cost_usd),0),4)    AS saved,
  ROUND(COALESCE(AVG(latency_ms),0))          AS avg_ms,
  ROUND(COALESCE(AVG(upstream_latency_ms),0)) AS prov_ms
FROM request_log
WHERE ts >= strftime('%Y-%m-%dT00:00:00Z','now')
" | awk -F'|' 'NR==1{
    printf "  Requests: %-6s  Cached: %-5s  Blocked: %-5s  In: %-8s  Out: %-8s  Cost: $%-8s  Saved: $%-8s  Avg: %sms  Prov: %sms\n",
           $1,$2,$3,$4,$5,$6,$7,$8,$9
}'
    echo ""

    # ── Per tenant today ─────────────────────────────────────────────
    echo "  ── Tenants today ───────────────────────────────────────────"
    printf "  %-20s  %8s  %10s  %10s  %10s  %12s\n" "TENANT" "REQUESTS" "IN TOK" "OUT TOK" "COST USD" "QUOTA LEFT"
    printf "  %-20s  %8s  %10s  %10s  %10s  %12s\n" "--------------------" "--------" "----------" "----------" "--------" "------------"
    sql "
SELECT
  COALESCE(t.slug, l.tenant_id)        AS tenant,
  COUNT(*)                              AS requests,
  COALESCE(SUM(l.input_tokens),0)      AS in_tok,
  COALESCE(SUM(l.output_tokens),0)     AS out_tok,
  ROUND(COALESCE(SUM(l.cost_usd),0),4) AS cost,
  ROUND(MIN(l.quota_remaining),4)      AS quota_left
FROM request_log l
LEFT JOIN cfg.tenant t ON t.id = l.tenant_id
WHERE l.ts >= strftime('%Y-%m-%dT00:00:00Z','now')
GROUP BY l.tenant_id
ORDER BY cost DESC
LIMIT 10
" | awk -F'|' '{
    quota = ($6 == "") ? "no limit" : "$" $6
    printf "  %-20s  %8s  %10s  %10s  $%-9s  %-12s\n", $1,$2,$3,$4,$5,quota
}'
    echo ""

    # ── Recent requests ───────────────────────────────────────────────
    echo "  ── Last 10 requests ────────────────────────────────────────"
    printf "  %-19s  %-12s  %-10s  %-24s  %-9s  %6s  %6s  %9s  %5s  %5s\n" \
        "TIME" "TENANT" "PROVIDER" "MODEL" "STATUS" "IN" "OUT" "COST" "MS" "PROV"
    printf "  %-19s  %-12s  %-10s  %-24s  %-9s  %6s  %6s  %9s  %5s  %5s\n" \
        "-------------------" "------------" "----------" "------------------------" "---------" "------" "------" "---------" "-----" "-----"
    sql "
SELECT
  substr(l.ts,1,19)                         AS ts,
  COALESCE(t.slug, substr(l.tenant_id,1,8)) AS tenant,
  l.provider,
  substr(l.model,1,24)                      AS model,
  l.status,
  l.input_tokens,
  l.output_tokens,
  ROUND(l.cost_usd,5)                       AS cost,
  l.latency_ms,
  l.cached,
  l.blocked,
  COALESCE(l.blocked_by,'')                 AS blocked_by,
  COALESCE(l.upstream_latency_ms,'')        AS prov_ms
FROM request_log l
LEFT JOIN cfg.tenant t ON t.id = l.tenant_id
ORDER BY l.ts DESC LIMIT 10
" | awk -F'|' '{
    if ($11 == "1")       tag = "[" $12 "]"
    else if ($10 == "1")  tag = "[cached]"
    else                  tag = $5
    printf "  %-19s  %-12s  %-10s  %-24s  %-9s  %6s  %6s  $%-8s  %5s  %5s\n",
           $1,$2,$3,$4,tag,$6,$7,$8,$9,$13
}'
    echo ""

    # ── Recent blocked ────────────────────────────────────────────────
    echo "  ── Last 10 blocked requests ────────────────────────────────"
    printf "  %-19s  %-12s  %-14s  %-30s  %5s  %5s\n" \
        "TIME" "TENANT" "BLOCKED BY" "REASON" "MS" "GRL"
    printf "  %-19s  %-12s  %-14s  %-30s  %5s  %5s\n" \
        "-------------------" "------------" "--------------" "------------------------------" "-----" "-----"
    sql "
SELECT
  substr(l.ts,1,19)                         AS ts,
  COALESCE(t.slug, substr(l.tenant_id,1,8)) AS tenant,
  COALESCE(l.blocked_by,'?')                AS blocked_by,
  COALESCE(l.block_reason,'')               AS reason,
  l.latency_ms,
  COALESCE(l.guardrail_latency_ms,'')       AS grl_ms
FROM request_log l
LEFT JOIN cfg.tenant t ON t.id = l.tenant_id
WHERE l.blocked = 1
ORDER BY l.ts DESC LIMIT 10
" | awk -F'|' 'BEGIN {
    L["S1"]="Violent Crimes";       L["S2"]="Non-Violent Crimes";
    L["S3"]="Sex Crimes";           L["S4"]="Child Exploitation";
    L["S5"]="Defamation";           L["S6"]="Specialized Advice";
    L["S7"]="Privacy";              L["S8"]="IP Infringement";
    L["S9"]="WMD/CBRN";             L["S10"]="Hate Speech";
    L["S11"]="Self-Harm";           L["S12"]="Explicit Sexual";
    L["S13"]="Elections";           L["S14"]="Code Abuse";
} {
    reason = $4
    if (reason ~ /^S[0-9]/) {
        n = split(reason, codes, /,[ ]*/); out = ""
        for (i=1; i<=n; i++) {
            lbl = (codes[i] in L) ? codes[i] ":" L[codes[i]] : codes[i]
            out = out (i>1 ? ", " : "") lbl
        }
        reason = substr(out, 1, 30)
    }
    printf "  %-19s  %-12s  %-14s  %-30s  %5s  %5s\n", $1,$2,$3,reason,$5,$6
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
