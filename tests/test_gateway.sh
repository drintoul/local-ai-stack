#!/usr/bin/env bash

# ==============================================================================
# FIRECRAWL-EXTENDED GATEWAY TESTS
# ==============================================================================
# Description:
#   Verbose tests for the extended stack: unified gateway (:18080), interact
#   service (stateful Playwright browser sessions), and MCP interface (:18081).
#   Covers: auth enforcement, /status probes, /ollama + /searxng front-door
#   proxies, console UI, interact session lifecycle, real browser actions
#   (click/fill/screenshot), SSRF guard, async jobs, and MCP tools/list.
#
# Prerequisites:
#   - curl, python3
#   - firecrawl-extended-{gateway,interact,mcp} running
#   - GATEWAY_API_KEY set in .env (auth checks fail over gracefully if empty)
#
# Environment Variables:
#   GATEWAY_HOST   Default: http://localhost:18080
#   MCP_HOST       Default: http://localhost:18081
#   GATEWAY_API_KEY  Read from .env when unset
#
# Usage:
#   ./test_gateway.sh
# ==============================================================================

GATEWAY_HOST="${GATEWAY_HOST:-http://localhost:18080}"
MCP_HOST="${MCP_HOST:-http://localhost:18081}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY_API_KEY="${GATEWAY_API_KEY:-$(grep '^GATEWAY_API_KEY=' "$DIR/.env" 2>/dev/null | cut -d= -f2)}"
AUTH="Authorization: Bearer $GATEWAY_API_KEY"

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

echo "${B}== Firecrawl Extended ($GATEWAY_HOST) ==${N}"

# 1. healthz (open, no auth) ----------------------------------------------------
T=$(now)
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$GATEWAY_HOST/healthz")
if [ "$CODE" = "200" ]; then pass "GET /healthz -> http 200 ($(($(now)-T))ms)"; else fail "GET /healthz" "http $CODE"; fi

# 2. auth posture on firecrawl paths (401 = bearer enforced, 200 = ALLOW_UNAUTHENTICATED)
T=$(now)
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$GATEWAY_HOST/v1/scrape" \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com"}')
if [ "$CODE" = "401" ]; then
  pass "unauthenticated /v1/scrape -> http 401, bearer enforced ($(($(now)-T))ms)"
elif [ "$CODE" = "200" ]; then
  pass "unauthenticated /v1/scrape -> http 200, ALLOW_UNAUTHENTICATED mode ($(($(now)-T))ms)"
else
  fail "unauth scrape" "unexpected http $CODE"
fi

# 3. authed scrape proxied to firecrawl ------------------------------------------
T=$(now)
MD_LEN=$(curl -s --max-time 60 -X POST "$GATEWAY_HOST/v1/scrape" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}' | \
  json "import json,sys; print(len(json.load(sys.stdin).get('data',{}).get('markdown','')))")
if [ -n "$MD_LEN" ] && [ "$MD_LEN" -gt 50 ]; then pass "authed /v1/scrape -> ${MD_LEN} chars markdown ($(($(now)-T))ms)"; else fail "authed scrape" "no markdown returned"; fi

# 4. /status probes all backends -------------------------------------------------
T=$(now)
STATUS=$(curl -s --max-time 15 "$GATEWAY_HOST/status" -H "$AUTH" | \
  json "import json,sys; d=json.load(sys.stdin); ok=[k for k,v in d.items() if v.get('status')=='ok']; print(f\"{len(ok)}/{len(d)}\", ','.join(ok))")
if [ "${STATUS%% *}" = "4/4" ]; then pass "GET /status -> all 4 probes ok [${STATUS#* }] ($(($(now)-T))ms)"; else fail "GET /status" "probes: ${STATUS:-unreachable}"; fi

# 5. /ollama front-door proxy (no auth) ------------------------------------------
T=$(now)
MODELS=$(curl -s --max-time 10 "$GATEWAY_HOST/ollama/api/tags" | \
  json "import json,sys; print(len(json.load(sys.stdin)['models']))")
if [ -n "$MODELS" ] && [ "$MODELS" -gt 0 ]; then pass "/ollama proxy -> ${MODELS} models, unauthenticated ($(($(now)-T))ms)"; else fail "/ollama proxy" "no model list"; fi

# 6. /searxng front-door proxy (no auth) -----------------------------------------
T=$(now)
RES=$(curl -s --max-time 20 "$GATEWAY_HOST/searxng/search?q=ollama&format=json" | \
  json "import json,sys; print(len(json.load(sys.stdin)['results']))")
if [ -n "$RES" ] && [ "$RES" -gt 0 ]; then pass "/searxng proxy -> ${RES} results ($(($(now)-T))ms)"; else fail "/searxng proxy" "no results"; fi

# 7. console UI ------------------------------------------------------------------
T=$(now)
HTML=$(curl -s --max-time 10 "$GATEWAY_HOST/" -H "$AUTH" | head -c 2000)
if echo "$HTML" | grep -qi "<html\|<!DOCTYPE"; then pass "console UI GET / -> HTML page ($(($(now)-T))ms)"; else fail "console UI" "no HTML"; fi

# --- interact service (via gateway) ---------------------------------------------

# 8. session lifecycle: create -> list -> delete ---------------------------------
T=$(now)
SID=$(curl -s --max-time 30 -X POST "$GATEWAY_HOST/v1/interact/sessions" -H "$AUTH" \
  -H 'Content-Type: application/json' -d '{}' | \
  json "import json,sys; d=json.load(sys.stdin); print(d.get('sessionId') or d.get('id') or '')")
if [ -z "$SID" ]; then
  fail "interact session lifecycle" "session create returned no id"
else
  LST=$(curl -s --max-time 10 "$GATEWAY_HOST/v1/interact/sessions" -H "$AUTH" | json "import json,sys; d=json.load(sys.stdin); ids=[s.get('id') or s.get('sessionId') for s in (d if isinstance(d,list) else d.get('sessions',[]))]; print('$SID' in ids)")
  DEL_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X DELETE "$GATEWAY_HOST/v1/interact/sessions/$SID" -H "$AUTH")
  if [ "$LST" = "True" ] && [ "$DEL_CODE" = "200" ]; then
    pass "interact session create/list/delete -> id ${SID:0:8}… ($(($(now)-T))ms)"
  else
    fail "interact session lifecycle" "listed=$LST delete=$DEL_CODE"
  fi
fi

# 9. actions: goto + screenshot (real browser screenshot) -------------------------
T=$(now)
RESP=$(curl -s --max-time 90 -X POST "$GATEWAY_HOST/v1/interact" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","actions":[{"type":"goto","url":"https://example.com"},{"type":"screenshot","fullPage":true}]}')
SHOT=$(echo "$RESP" | json "import json,sys; d=json.load(sys.stdin); shots=[a.get('screenshot','') for a in d.get('actionsLog',[])]; print(len(max(shots,key=len,default='')))")
MD=$(echo "$RESP" | json "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',{}).get('markdown','') or ''))")
if [ -n "$SHOT" ] && [ "$SHOT" -gt 1000 ] && [ -n "$MD" ] && [ "$MD" -gt 50 ]; then
  pass "interact goto+screenshot -> ${SHOT}b base64 png, ${MD}c markdown ($(($(now)-T))ms)"
else
  fail "interact actions" "screenshot=${SHOT:-0}b markdown=${MD:-0}c"
fi

# 10. real browser form: fill + click on a login page ------------------------------
T=$(now)
OUTCOME=$(curl -s --max-time 90 -X POST "$GATEWAY_HOST/v1/interact" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://quotes.toscrape.com/login","actions":[{"type":"fill","selector":"#username","value":"test"},{"type":"fill","selector":"#password","value":"test"},{"type":"click","selector":"input[type=submit]"},{"type":"waitForURL","url":"**/"}]}' | \
  json "import json,sys; d=json.load(sys.stdin); print(d.get('success'), d.get('data',{}).get('url',''))")
if echo "$OUTCOME" | grep -q "True"; then pass "interact form fill+click -> navigated to ${OUTCOME#* } ($(($(now)-T))ms)"; else fail "interact form" "$OUTCOME"; fi

# 11. SSRF guard: private target refused -------------------------------------------
T=$(now)
ERR=$(curl -s --max-time 20 -X POST "$GATEWAY_HOST/v1/interact" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"http://169.254.169.254/latest/meta-data"}')
if echo "$ERR" | json "import json,sys; d=json.load(sys.stdin); print(d.get('success'))" | grep -q "False"; then
  pass "interact SSRF guard -> refused private target ($(($(now)-T))ms)"
else
  fail "interact SSRF guard" "private target not refused: $(echo "$ERR" | head -c 120)"
fi

# 12. async job lifecycle ----------------------------------------------------------
T=$(now)
JID=$(curl -s --max-time 20 -X POST "$GATEWAY_HOST/v1/interact/async" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","actions":[{"type":"goto","url":"https://example.com"}]}' | \
  json "import json,sys; print(json.load(sys.stdin).get('id',''))")
JOB_STATE=""
if [ -n "$JID" ]; then
  for i in 1 2 3 4 5 6 7 8; do
    sleep 3
    JOB_STATE=$(curl -s --max-time 10 "$GATEWAY_HOST/v1/interact/jobs/$JID" -H "$AUTH" | \
      json "import json,sys; print(json.load(sys.stdin).get('status',''))")
    [ "$JOB_STATE" != "running" ] && break
  done
fi
if [ "$JOB_STATE" = "completed" ]; then pass "interact async job $JID -> completed ($(($(now)-T))ms)"; else fail "interact async job" "status=${JOB_STATE:-no job}"; fi

# 13. prompt mode: Ollama plans the actions ------------------------------------------
T=$(now)
P_OUT=$(curl -s --max-time 180 -X POST "$GATEWAY_HOST/v1/interact" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://quotes.toscrape.com","prompt":"Get the text of the first quote on the page"}' | \
  json "import json,sys; d=json.load(sys.stdin); print(d.get('success'), len(d.get('answer') or ''), len(d.get('plannedActions') or d.get('actionsLog') or []))")
if echo "$P_OUT" | grep -q "True"; then
  pass "interact prompt mode -> Ollama planned+ran ($(echo "$P_OUT" | awk '{print $2"c answer, "$3" actions"}'), $(($(now)-T))ms)"
else
  fail "interact prompt mode" "${P_OUT:-timeout}"
fi

# --- MCP interface (:18081) -------------------------------------------------------

# 14. MCP initialize --------------------------------------------------------------
T=$(now)
MCP_RESP=$(curl -s --max-time 15 -X POST "$MCP_HOST/mcp" -H "$AUTH" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1.0"}}}')
MCP_VER=$(echo "$MCP_RESP" | grep -o '"protocolVersion":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$MCP_VER" ]; then pass "MCP initialize -> protocol $MCP_VER ($(($(now)-T))ms)"; else fail "MCP initialize" "$(echo "$MCP_RESP" | head -c 100)"; fi

# 15. MCP tools/list ---------------------------------------------------------------
T=$(now)
TOOLS=$(curl -s --max-time 15 -X POST "$MCP_HOST/mcp" -H "$AUTH" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | \
  grep -o '"name":"[a-z_]*"' | cut -d'"' -f4 | tr '\n' ' ')
TOOL_N=$(echo "$TOOLS" | wc -w)
if [ "$TOOL_N" -gt 0 ]; then pass "MCP tools/list -> $TOOL_N tools [$TOOLS] ($(($(now)-T))ms)"; else fail "MCP tools/list" "no tools"; fi

# 16. /containers stack health report (docker socket) -----------------------------
T=$(now)
REPORT=$(curl -s --max-time 15 "$GATEWAY_HOST/containers" -H "$AUTH" | \
  json "import json,sys; l=json.load(sys.stdin); healthy=sum(1 for c in l if c.get('health') in ('healthy','no-healthcheck')); print(f'{healthy}/{len(l)}')")
if [ -n "$REPORT" ] && [ "${REPORT%%/*}" = "${REPORT##*/}" ] && [ "${REPORT%%/*}" -gt 0 ]; then
  pass "GET /containers -> $REPORT up ($(($(now)-T))ms)"
else
  fail "GET /containers" "report: ${REPORT:-unreachable}"
fi

echo
echo "${B}Firecrawl Extended:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
