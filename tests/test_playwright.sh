#!/usr/bin/env bash

# ==============================================================================
# PLAYWRIGHT CONTAINER TESTS
# ==============================================================================
# Description:
#   Verbose tests for the firecrawl-playwright microservice, including edge
#   cases: container health/uptime, direct scrape, wait_after_load option,
#   SSRF protection (private-address blocking), and end-to-end JS rendering
#   through the Firecrawl API. Each check reports wall-clock time/details.
#
#   The service has no published host port, so direct checks run through
#   `docker exec` on the firecrawl container (which shares its networks).
#
# Prerequisites:
#   - curl, python3, docker
#   - firecrawl and firecrawl-playwright containers running
#
# Environment Variables:
#   FIRECRAWL_HOST       Default: http://localhost:3002
#   PW_CONTAINER         Default: firecrawl-playwright
#   EXEC_CONTAINER       Container used to reach the internal network
#                        (default: firecrawl)
#
# Usage:
#   ./test_playwright.sh
# ==============================================================================

FIRECRAWL_HOST="${FIRECRAWL_HOST:-http://localhost:3002}"
PW_CONTAINER="${PW_CONTAINER:-firecrawl-playwright}"
EXEC_CONTAINER="${EXEC_CONTAINER:-firecrawl}"

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

echo "${B}== Playwright ($PW_CONTAINER) ==${N}"

if ! command -v docker >/dev/null 2>&1; then
  skip "all checks" "docker not available on this host"
  echo; echo "${B}Playwright:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
  exit 0
fi

# 1. Container health + uptime ---------------------------------------------------
T=$(now)
STATE=$(docker inspect -f '{{.State.Health.Status}}|{{.State.StartedAt}}|{{.RestartCount}}' "$PW_CONTAINER" 2>/dev/null)
HEALTH=${STATE%%|*}; REST=${STATE##*|}; STARTED=$(echo "$STATE" | cut -d'|' -f2 | cut -dT -f1)
if [ "$HEALTH" = "healthy" ]; then
  pass "container healthy since $STARTED, restarts: $REST ($(($(now)-T))ms)"
elif [ -z "$HEALTH" ]; then
  fail "container" "$PW_CONTAINER not found"
else
  fail "container" "health status: $HEALTH"
fi

# 2. Direct scrape through the internal network ----------------------------------
if docker ps --format '{{.Names}}' | grep -qx "$EXEC_CONTAINER"; then
  T=$(now)
  PW_LEN=$(docker exec "$EXEC_CONTAINER" node -e "
    fetch('http://$PW_CONTAINER:3000/scrape', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({url: 'https://example.com', timeout: 30000})
    }).then(r => r.text()).then(t => {
      try { const d = JSON.parse(t); console.log((d.content||'').length) }
      catch { console.log(-1) }
    }).catch(() => console.log(-1))" 2>/dev/null)
  if [ -n "$PW_LEN" ] && [ "$PW_LEN" -gt 0 ]; then
    pass "POST /scrape -> ${PW_LEN} chars rendered HTML (internal net, $(($(now)-T))ms)"
  else
    fail "POST /scrape" "service returned no content"
  fi

  # 3. wait_after_load option (edge: render-delay option accepted) ---------------
  T=$(now)
  PW_WAIT=$(docker exec "$EXEC_CONTAINER" node -e "
    fetch('http://$PW_CONTAINER:3000/scrape', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({url: 'https://example.com', timeout: 30000, wait_after_load: 1500})
    }).then(r => r.text()).then(t => console.log(t.includes('<html') ? 'ok' : 'bad'))
      .catch(() => console.log('bad'))" 2>/dev/null)
  if [ "$PW_WAIT" = "ok" ]; then
    pass "wait_after_load=1500 honored -> rendered HTML ($(($(now)-T))ms)"
  else
    fail "wait_after_load" "scrape with render delay failed"
  fi

  # 4. Concurrent scrape pool (edge: MAX_CONCURRENT_PAGES parallel renders) ------
  T=$(now)
  PW_PAR=$(docker exec "$EXEC_CONTAINER" node -e "
    Promise.all([1,2,3].map(() =>
      fetch('http://$PW_CONTAINER:3000/scrape', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({url: 'https://example.com', timeout: 30000})
      }).then(r => r.text())))
      .then(rs => console.log(rs.every(t => t.includes('<html')) ? 'ok' : 'bad'))
      .catch(() => console.log('bad'))" 2>/dev/null)
  if [ "$PW_PAR" = "ok" ]; then
    pass "3 parallel scrapes -> all rendered (page pool OK, $(($(now)-T))ms)"
  else
    fail "parallel scrapes" "one or more concurrent renders failed"
  fi

  # 5. SSRF protection (edge: cloud-metadata IP blocked) -------------------------
  T=$(now)
  SSRF=$(docker exec "$EXEC_CONTAINER" node -e "
    fetch('http://$PW_CONTAINER:3000/scrape', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({url: 'http://169.254.169.254/latest/meta-data', timeout: 15000})
    }).then(r => r.text()).then(t => {
      try { const d = JSON.parse(t); console.log((d.pageStatusCode||'') + '|' + (d.pageError||'')) }
      catch { console.log('|') }
    }).catch(() => console.log('|'))" 2>/dev/null)
  SSRF_SC=${SSRF%%|*}; SSRF_ERR=${SSRF##*|}
  if [ "$SSRF_SC" = "403" ] && echo "$SSRF_ERR" | grep -qi "private"; then
    pass "SSRF guard blocks 169.254.169.254 -> 403 \"${SSRF_ERR:0:60}\" ($(($(now)-T))ms)"
  else
    fail "SSRF guard" "expected 403 private-address block, got status=$SSRF_SC"
  fi
else
  skip "direct service checks" "exec container '$EXEC_CONTAINER' not running"
fi

# 6. End-to-end JS rendering via Firecrawl ---------------------------------------
# quotes.toscrape.com/js/ renders quotes via JavaScript only -- getting quote
# text back proves the request flowed Firecrawl -> Playwright -> real Chromium.
T=$(now)
JS_LEN=$(curl -sf --max-time 90 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://quotes.toscrape.com/js/","formats":["markdown"],"waitFor":2000}' | \
  json "import json,sys; d=json.load(sys.stdin); md=d.get('data',{}).get('markdown',''); print(len(md) if 'Einstein' in md else 0)")
if [ -n "$JS_LEN" ] && [ "$JS_LEN" -gt 0 ]; then
  pass "JS-only page via Firecrawl -> ${JS_LEN} chars incl. Einstein quote ($(($(now)-T))ms)"
else
  fail "JS-only page" "no JS-rendered content returned"
fi

echo
echo "${B}Playwright:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -eq 0 ]
