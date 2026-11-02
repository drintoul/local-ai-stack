#!/usr/bin/env bash

# ==============================================================================
# FIRECRAWL CONTAINER TESTS
# ==============================================================================
# Description:
#   Verbose health/functionality tests for the Firecrawl API service,
#   including edge cases: health, single + multi-format scrape, missing-URL
#   rejection, unreachable-domain graceful failure, search (SearXNG backend)
#   with limit enforcement, URL map, and the async crawl job lifecycle.
#   Each check reports wall-clock time and response details.
#
# Prerequisites:
#   - curl, python3
#   - Firecrawl running and reachable
#
# Environment Variables:
#   FIRECRAWL_HOST   Default: http://localhost:3002
#   CRAWL_TIMEOUT    Seconds to wait for crawl completion (default: 90)
#
# Usage:
#   ./test_firecrawl.sh
# ==============================================================================

FIRECRAWL_HOST="${FIRECRAWL_HOST:-http://localhost:3002}"
CRAWL_TIMEOUT="${CRAWL_TIMEOUT:-90}"

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

echo "${B}== Firecrawl ($FIRECRAWL_HOST) ==${N}"

# 1. Health endpoint -----------------------------------------------------------
T=$(now)
if curl -sf --max-time 10 "$FIRECRAWL_HOST/" | grep -q "Firecrawl"; then
  pass "GET / health endpoint ($(($(now)-T))ms)"
else
  fail "GET /" "no response"
fi

# 2. Single-page scrape --------------------------------------------------------
T=$(now)
SCRAPE_LEN=$(curl -sf --max-time 60 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}' | \
  json "import json,sys; d=json.load(sys.stdin); print(len(d['data']['markdown']) if d.get('success') else 0)")
if [ -n "$SCRAPE_LEN" ] && [ "$SCRAPE_LEN" -gt 0 ]; then
  pass "v1/scrape example.com -> ${SCRAPE_LEN} chars markdown ($(($(now)-T))ms)"
else
  fail "v1/scrape" "scrape failed or empty markdown"
fi

# 3. Multi-format scrape (edge: all requested formats populated) -----------------
T=$(now)
FMT_OK=$(curl -sf --max-time 60 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown","html","links"]}' | \
  json "import json,sys; d=json.load(sys.stdin).get('data',{}); print('ok' if all(d.get(k) for k in ('markdown','html','links')) else '')")
if [ "$FMT_OK" = "ok" ]; then
  pass "v1/scrape multi-format -> markdown+html+links all populated ($(($(now)-T))ms)"
else
  fail "v1/scrape multi-format" "one or more formats missing"
fi

# 4. Missing URL rejection (edge: validation 400) --------------------------------
T=$(now)
BAD_INFO=$(curl -s -w '|%{http_code}' --max-time 15 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' -d '{}')
BAD_CODE=${BAD_INFO##*|}
BAD_OK=$(echo "${BAD_INFO%|*}" | json "import json,sys; d=json.load(sys.stdin); print(d.get('code','') if not d.get('success') else '')")
if [ "$BAD_CODE" = "400" ] && [ "$BAD_OK" = "BAD_REQUEST" ]; then
  pass "missing url -> 400 BAD_REQUEST ($(($(now)-T))ms)"
else
  fail "missing url" "expected 400 BAD_REQUEST, got http $BAD_CODE"
fi

# 5. Unreachable domain (edge: success envelope w/ error metadata) ---------------
T=$(now)
UNREACH=$(curl -sf --max-time 60 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://this-domain-does-not-exist-xyz123.com"}' | \
  json "
import json,sys; d=json.load(sys.stdin)
err=d.get('data',{}).get('metadata',{}).get('error','')
sc=d.get('data',{}).get('metadata',{}).get('statusCode','')
print(sc, 'has_error' if err else 'no_error')")
UNREACH_SC=$(echo "$UNREACH" | cut -d' ' -f1)
UNREACH_ERR=$(echo "$UNREACH" | cut -d' ' -f2)
if [ "$UNREACH_ERR" = "has_error" ]; then
  pass "unreachable domain -> graceful error (statusCode=$UNREACH_SC, metadata.error set, $(($(now)-T))ms)"
else
  fail "unreachable domain" "no error metadata for dead domain"
fi

# 6. Search honoring limit (edge: limit=2 yields exactly 2) ----------------------
T=$(now)
for a in 1 2; do
  SEARCH_COUNT=$(curl -sf --max-time 60 -X POST "$FIRECRAWL_HOST/v1/search" \
    -H 'Content-Type: application/json' \
    -d '{"query":"web scraping","limit":2}' | \
    json "import json,sys; print(len(json.load(sys.stdin).get('data',[])))")
  [ -n "$SEARCH_COUNT" ] && [ "$SEARCH_COUNT" -gt 0 ] && break
  [ "$a" = 1 ] && sleep 8   # SearXNG engines can be briefly suspended (429/CAPTCHA)
done
if [ "$SEARCH_COUNT" = "2" ]; then
  pass "v1/search limit=2 -> exactly 2 results via SearXNG ($(($(now)-T))ms)"
elif [ -n "$SEARCH_COUNT" ] && [ "$SEARCH_COUNT" -gt 0 ]; then
  fail "v1/search" "limit=2 returned $SEARCH_COUNT results"
elif [ "$(curl -s --max-time 20 'http://localhost:8088/search?q=test&format=json' | json "import json,sys; print(len(json.load(sys.stdin).get('unresponsive_engines',[])))" )" -gt 0 ]; then
  skip "v1/search" "SearXNG engines suspended upstream (CAPTCHA/429) — retest in a few minutes"
else
  fail "v1/search" "SearXNG backend integration failed"
fi

# 7. URL map -------------------------------------------------------------------
T=$(now)
MAP_COUNT=$(curl -sf --max-time 60 -X POST "$FIRECRAWL_HOST/v1/map" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://quotes.toscrape.com","limit":10}' | \
  json "import json,sys; print(len(json.load(sys.stdin).get('links',[])))")
if [ -n "$MAP_COUNT" ] && [ "$MAP_COUNT" -gt 0 ]; then
  pass "v1/map -> $MAP_COUNT links discovered ($(($(now)-T))ms)"
else
  fail "v1/map" "no links discovered"
fi

# 8. Async crawl job lifecycle ---------------------------------------------------
T=$(now)
CRAWL_ID=$(curl -sf --max-time 30 -X POST "$FIRECRAWL_HOST/v1/crawl" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","limit":1,"scrapeOptions":{"formats":["markdown"]}}' | \
  json "import json,sys; print(json.load(sys.stdin).get('id',''))")

if [ -z "$CRAWL_ID" ]; then
  fail "v1/crawl" "job was not accepted"
else
  STATUS=""; PAGES=0; ELAPSED=0
  while [ "$ELAPSED" -lt "$CRAWL_TIMEOUT" ]; do
    RESP=$(curl -sf --max-time 10 "$FIRECRAWL_HOST/v1/crawl/$CRAWL_ID")
    STATUS=$(echo "$RESP" | json "import json,sys; print(json.load(sys.stdin).get('status',''))")
    PAGES=$(echo "$RESP" | json "import json,sys; print(len(json.load(sys.stdin).get('data',[])))")
    [ "$STATUS" = "completed" ] && break
    sleep 3; ELAPSED=$((ELAPSED + 3))
  done
  if [ "$STATUS" = "completed" ] && [ "${PAGES:-0}" -gt 0 ]; then
    pass "v1/crawl job $CRAWL_ID -> completed, $PAGES page(s), ${ELAPSED}s total"
  else
    fail "v1/crawl" "status=$STATUS pages=$PAGES after ${ELAPSED}s"
  fi
fi

# 9. Batch scrape job lifecycle ---------------------------------------------------
T=$(now)
BATCH_ID=$(curl -sf --max-time 30 -X POST "$FIRECRAWL_HOST/v1/batch/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"urls":["https://example.com","https://quotes.toscrape.com"],"formats":["markdown"]}' | \
  json "import json,sys; print(json.load(sys.stdin).get('id',''))")

if [ -z "$BATCH_ID" ]; then
  fail "v1/batch/scrape" "job was not accepted"
else
  B_STATUS=""; B_DONE=0; ELAPSED=0
  while [ "$ELAPSED" -lt "$CRAWL_TIMEOUT" ]; do
    B_RESP=$(curl -sf --max-time 10 "$FIRECRAWL_HOST/v1/batch/scrape/$BATCH_ID")
    B_STATUS=$(echo "$B_RESP" | json "import json,sys; print(json.load(sys.stdin).get('status',''))")
    B_DONE=$(echo "$B_RESP" | json "import json,sys; print(len(json.load(sys.stdin).get('data',[])))")
    [ "$B_STATUS" = "completed" ] && break
    sleep 3; ELAPSED=$((ELAPSED + 3))
  done
  if [ "$B_STATUS" = "completed" ] && [ "${B_DONE:-0}" -ge 2 ]; then
    pass "v1/batch/scrape job $BATCH_ID -> completed, $B_DONE pages, ${ELAPSED}s total"
  else
    fail "v1/batch/scrape" "status=$B_STATUS pages=$B_DONE after ${ELAPSED}s"
  fi
fi

# 10. Scrape actions (edge: playwright engine lacks action support) ----------------
# Note: API returns HTTP 400 here, so use -s (not -sf) to keep the error body.
T=$(now)
ACT_ERR=$(curl -s --max-time 30 -X POST "$FIRECRAWL_HOST/v1/scrape" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"],"actions":[{"type":"wait","milliseconds":500}]}' | \
  json "import json,sys; d=json.load(sys.stdin); print('ok' if not d.get('success') and 'not supported' in str(d.get('error','')) else '')")
if [ "$ACT_ERR" = "ok" ]; then
  pass "scrape actions -> graceful 'not supported by engines' error ($(($(now)-T))ms) [needs Fire Engine]"
else
  fail "scrape actions" "expected graceful not-supported error"
fi

# 11. Structured extraction pipeline (scrape -> Ollama format:json) --------------
# Exercises tests/extract.py: Firecrawl renders markdown, Ollama extracts
# schema-shaped JSON. This is the local replacement for /v1/extract.
T=$(now)
EXTRACT_DIR="$(cd "$(dirname "$0")" && pwd)"
EX_OK=$("$EXTRACT_DIR/extract.py" https://quotes.toscrape.com \
  "Extract the first quote's author as {author: string}" 2>/dev/null | \
  json "import json,sys; d=json.load(sys.stdin); print('ok' if 'Einstein' in str(d.get('author','')) else '')")
if [ "$EX_OK" = "ok" ]; then
  pass "extract.py pipeline -> author=Einstein (scrape+Ollama, $(($(now)-T))ms)"
else
  fail "extract.py pipeline" "extraction did not return Einstein"
fi

echo
echo "${B}Firecrawl:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -eq 0 ]
