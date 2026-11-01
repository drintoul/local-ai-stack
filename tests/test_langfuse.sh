#!/usr/bin/env bash

# ==============================================================================
# LANGFUSE CONTAINER TESTS
# ==============================================================================
# Description:
#   Verbose tests for the Langfuse observability stack (v4): container health
#   for all six services, health/UI endpoints, OTEL trace ingestion (the v4
#   native path), trace retrieval, and unauthenticated rejection.
#   API keys are read from ../.env (LANGFUSE_INIT_*) unless overridden.
#
# Prerequisites:
#   - curl, python3, docker
#   - Langfuse stack running and initialized
#
# Environment Variables:
#   LANGFUSE_HOST        Default: http://localhost:3000
#   LANGFUSE_PUBLIC_KEY  Default: read from ../.env
#   LANGFUSE_SECRET_KEY  Default: read from ../.env
#   TRACE_TIMEOUT        Seconds to wait for trace to appear (default: 60)
#
# Usage:
#   ./test_langfuse.sh
# ==============================================================================

LANGFUSE_HOST="${LANGFUSE_HOST:-http://localhost:3000}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-$(grep '^LANGFUSE_INIT_PUBLIC_KEY' "$ENV_FILE" 2>/dev/null | cut -d= -f2)}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-$(grep '^LANGFUSE_INIT_SECRET_KEY' "$ENV_FILE" 2>/dev/null | cut -d= -f2)}"
TRACE_TIMEOUT="${TRACE_TIMEOUT:-60}"

PASS=0; FAIL=0; SKIP=0

if [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

[ -t 1 ] && [ -z "$SMOKE_RUNNER" ] && clear

now()  { date +%s%3N; }
pass() { PASS=$((PASS + 1)); echo "  ${G}✓${N} $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ${R}✗${N} $1${2:+ -- $2}"; }
skip() { SKIP=$((SKIP + 1)); echo "  ${Y}-${N} $1 -- $2"; }
json() { python3 -c "$1" 2>/dev/null; }

echo "${B}== Langfuse ($LANGFUSE_HOST) ==${N}"

# 1. All six containers healthy --------------------------------------------------
T=$(now)
UNHEALTHY=""
for c in langfuse-web langfuse-worker langfuse-postgres langfuse-clickhouse langfuse-minio langfuse-redis; do
  H=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)
  [ "$H" = "healthy" ] || UNHEALTHY="$UNHEALTHY $c:${H:-missing}"
done
if [ -z "$UNHEALTHY" ]; then
  pass "all 6 containers healthy (web, worker, postgres, clickhouse, minio, redis, $(($(now)-T))ms)"
else
  fail "container health" "unhealthy:$UNHEALTHY"
fi

# 2. Public health endpoint --------------------------------------------------------
T=$(now)
HF=$(curl -sf --max-time 10 "$LANGFUSE_HOST/api/public/health" | \
  json "import json,sys; d=json.load(sys.stdin); print(d.get('status',''), d.get('version',''))")
HF_STATUS=$(echo "$HF" | cut -d' ' -f1); HF_VER=$(echo "$HF" | cut -d' ' -f2)
if [ "$HF_STATUS" = "OK" ]; then
  pass "api/public/health -> OK v$HF_VER ($(($(now)-T))ms)"
else
  fail "api/public/health" "got: ${HF:-<no response>}"
fi

# 3. Web UI ------------------------------------------------------------------------
T=$(now)
UI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$LANGFUSE_HOST/")
if [ "$UI_CODE" = "200" ]; then
  pass "GET / web UI -> http 200 ($(($(now)-T))ms)"
else
  fail "GET /" "http $UI_CODE"
fi

# 4. OTEL trace ingestion (v4 native path) -------------------------------------------
T=$(now)
TRACE_ID=$(python3 -c "import secrets; print(secrets.token_hex(16))")
SPAN_ID=$(python3 -c "import secrets; print(secrets.token_hex(8))")
TS=$(python3 -c "import time; print(int(time.time()*1e9))")
OTEL_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -X POST "$LANGFUSE_HOST/api/public/otel/v1/traces" \
  -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoke-test\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"smoke\"},\"spans\":[{\"traceId\":\"$TRACE_ID\",\"spanId\":\"$SPAN_ID\",\"name\":\"smoke-test-trace\",\"kind\":1,\"startTimeUnixNano\":\"$TS\",\"endTimeUnixNano\":\"$TS\",\"status\":{\"code\":1}}]}]}]}")
if [ "$OTEL_CODE" = "200" ]; then
  pass "OTEL /api/public/otel/v1/traces accepted (http 200, $(($(now)-T))ms)"
elif [ -z "$LANGFUSE_PUBLIC_KEY" ] || [ -z "$LANGFUSE_SECRET_KEY" ]; then
  skip "OTEL ingestion" "no API keys (check LANGFUSE_INIT_* in .env)"
else
  fail "OTEL ingestion" "http $OTEL_CODE"
fi

# 5. Trace lands in ClickHouse (poll: async via worker) -------------------------------
# v4 events_only mode has no legacy REST /traces API -- verify the span was
# written by querying the events_full table in ClickHouse directly.
T=$(now)
FOUND=""; ELAPSED=0
while [ "$ELAPSED" -lt "$TRACE_TIMEOUT" ]; do
  FOUND=$(docker exec langfuse-clickhouse clickhouse-client \
    --query "SELECT count() FROM events_full WHERE name = 'smoke-test-trace'" 2>/dev/null)
  [ "$FOUND" -gt 0 ] 2>/dev/null && break
  sleep 3; ELAPSED=$((ELAPSED + 3))
done
if [ "${FOUND:-0}" -gt 0 ] 2>/dev/null; then
  pass "ingested span written to ClickHouse events_full (${ELAPSED}s to land)"
elif ! docker ps --format '{{.Names}}' | grep -qx langfuse-clickhouse; then
  skip "trace persistence" "clickhouse container not running"
else
  fail "trace persistence" "span not found in events_full after ${TRACE_TIMEOUT}s"
fi

# 6. Unauthenticated rejection (edge: bad creds -> 401) -------------------------------
T=$(now)
AUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST "$LANGFUSE_HOST/api/public/otel/v1/traces" \
  -u "pk-lf-invalid:sk-lf-invalid" \
  -H 'Content-Type: application/json' -d '{}')
if [ "$AUTH_CODE" = "401" ]; then
  pass "invalid credentials -> http 401 ($(($(now)-T))ms)"
else
  fail "invalid credentials" "expected 401, got http $AUTH_CODE"
fi

echo
echo "${B}Langfuse:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -eq 0 ]
