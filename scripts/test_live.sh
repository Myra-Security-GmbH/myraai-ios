#!/usr/bin/env bash
# scripts/test_live.sh — smoke test a real gateway request
#
# Uses myratest/prod by default; override with env vars.
#
# Usage:
#   ./scripts/test_live.sh
#   TENANT=acme GATEWAY=prod TOKEN=<token> ./scripts/test_live.sh

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8081}"
TENANT="${TENANT:-myratest}"
GATEWAY="${GATEWAY:-prod}"
TOKEN="${TOKEN:-2688152ca40c3ef89662d6638b83bb82ba3c592734302e8bd3498492e5fda730}"

BASE="$GATEWAY_URL/v1/$TENANT/$GATEWAY/anthropic"

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; echo "        $2"; FAILED=$((FAILED+1)); }
FAILED=0

echo ""
echo "=== Live gateway smoke test ==="
echo "    $BASE"
echo ""

# ---------------------------------------------------------------------------
# 1. Health check
# ---------------------------------------------------------------------------
echo "1. Health check"
status=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/healthz")
if [[ "$status" == "200" ]]; then pass "GET /healthz → 200"
else fail "GET /healthz" "HTTP $status"; fi

# ---------------------------------------------------------------------------
# 2. Auth rejected without token
# ---------------------------------------------------------------------------
echo "2. Auth (no token)"
body=$(curl -s -X POST "$BASE/v1/messages" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}')
code=$(echo "$body" | grep -o '"code":"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ "$code" == "unauthorized" ]]; then pass "no token → 401 unauthorized"
else fail "no token" "got: $body"; fi

# ---------------------------------------------------------------------------
# 3. Auth rejected with wrong token
# ---------------------------------------------------------------------------
echo "3. Auth (bad token)"
body=$(curl -s -X POST "$BASE/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: deadbeef" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}')
code=$(echo "$body" | grep -o '"code":"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ "$code" == "unauthorized" ]]; then pass "bad token → 401 unauthorized"
else fail "bad token" "got: $body"; fi

# ---------------------------------------------------------------------------
# 4. Real request — non-streaming
# ---------------------------------------------------------------------------
echo "4. Real request (non-streaming)"
response=$(curl -s -w "\n__STATUS__%{http_code}" \
  -X POST "$BASE/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $TOKEN" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 32,
    "messages": [{"role": "user", "content": "Reply with exactly: OK"}]
  }')
http_status=$(echo "$response" | grep '__STATUS__' | sed 's/__STATUS__//')
body=$(echo "$response" | grep -v '__STATUS__')

if [[ "$http_status" == "200" ]]; then
  content=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null || echo "")
  pass "HTTP 200 — response: $content"
else
  fail "non-streaming" "HTTP $http_status — $body"
fi

# ---------------------------------------------------------------------------
# 5. Real request — streaming
# ---------------------------------------------------------------------------
echo "5. Real request (streaming)"
stream_out=$(curl -s -N \
  -X POST "$BASE/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $TOKEN" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 32,
    "stream": true,
    "messages": [{"role": "user", "content": "Reply with exactly: STREAM_OK"}]
  }' 2>&1 | head -20)

if echo "$stream_out" | grep -q "data:"; then
  pass "streaming SSE chunks received"
else
  fail "streaming" "no SSE data lines: $stream_out"
fi

# ---------------------------------------------------------------------------
# 6. Check request was logged
# ---------------------------------------------------------------------------
echo "6. Log written"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DB="${AIG_DATA_DIR:-$SCRIPT_DIR/../data}/logs.db"
if [[ -f "$LOGS_DB" ]]; then
  count=$(sqlite3 "$LOGS_DB" "SELECT COUNT(*) FROM request_logs WHERE provider='anthropic' AND status=200;" 2>/dev/null || echo "0")
  if [[ "$count" -gt "0" ]]; then pass "logs.db has $count anthropic 200 entries"
  else fail "log written" "0 successful anthropic entries in logs.db"; fi
else
  fail "log written" "logs.db not found at $LOGS_DB"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "All tests passed."
else
  echo "$FAILED test(s) FAILED."
  exit 1
fi
echo ""
