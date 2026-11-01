#!/usr/bin/env bash

# ==============================================================================
# SEARXNG CONTAINER TESTS
# ==============================================================================
# Description:
#   Verbose health/functionality tests for the SearXNG metasearch service,
#   including edge cases: web UI, JSON API with engine health, pagination,
#   URL-encoded special characters, empty-query rejection, HTML results,
#   and autocomplete. Each check reports wall-clock time and details.
#
# Prerequisites:
#   - curl, python3
#   - SearXNG running and reachable
#   - 'json' listed under formats: in searxng/settings.yml (for JSON tests)
#
# Environment Variables:
#   SEARXNG_HOST   Default: http://localhost:8088
#
# Usage:
#   ./test_searxng.sh
# ==============================================================================

SEARXNG_HOST="${SEARXNG_HOST:-http://localhost:8088}"

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

echo "${B}== SearXNG ($SEARXNG_HOST) ==${N}"

# 1. Web UI homepage -----------------------------------------------------------
T=$(now)
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SEARXNG_HOST/")
if [ "$CODE" = "200" ]; then
  pass "GET / web UI -> http 200 ($(($(now)-T))ms)"
else
  fail "GET /" "http $CODE"
fi

# 2. JSON search API (+ engine health) ------------------------------------------
T=$(now)
SEARCH_INFO=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=ollama&format=json" | \
  json "
import json,sys; d=json.load(sys.stdin)
rs=d.get('results',[]); ue=d.get('unresponsive_engines',[])
print(len(rs), len(ue), rs[0]['title'][:50].replace(' ','_') if rs else '')")
RESULT_COUNT=$(echo "$SEARCH_INFO" | cut -d' ' -f1)
DEAD_ENGINES=$(echo "$SEARCH_INFO" | cut -d' ' -f2)
TOP_TITLE=$(echo "$SEARCH_INFO" | cut -d' ' -f3- | tr '_' ' ')
if [ -n "$RESULT_COUNT" ] && [ "$RESULT_COUNT" -gt 0 ]; then
  pass "search format=json -> $RESULT_COUNT results, top: \"$TOP_TITLE\", unresponsive engines: $DEAD_ENGINES ($(($(now)-T))ms)"
else
  fail "search format=json" "no results (check formats: in settings.yml)"
fi

# 3. Pagination (edge: pageno=2 returns distinct page) ---------------------------
T=$(now)
PAGE2_COUNT=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=ollama&format=json&pageno=2" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
if [ -n "$PAGE2_COUNT" ] && [ "$PAGE2_COUNT" -gt 0 ]; then
  pass "search pageno=2 -> $PAGE2_COUNT results ($(($(now)-T))ms)"
else
  fail "search pageno=2" "no results on page 2"
fi

# 4. Special characters (edge: URL-encoded reserved chars) -----------------------
T=$(now)
ENCODED_COUNT=$(curl -sf --get --max-time 30 "$SEARXNG_HOST/search" \
  --data-urlencode 'q=C++ vs C#: differences & similarities' \
  --data-urlencode 'format=json' | \
  json "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
if [ -n "$ENCODED_COUNT" ] && [ "$ENCODED_COUNT" -gt 0 ]; then
  pass "URL-encoded query 'C++ vs C#...' -> $ENCODED_COUNT results ($(($(now)-T))ms)"
else
  fail "URL-encoded query" "no results for special characters"
fi

# 5. Empty query rejection (edge: graceful 4xx, not 5xx) -------------------------
T=$(now)
EMPTY_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "$SEARXNG_HOST/search?q=&format=json")
if [ "$EMPTY_CODE" = "400" ] || [ "$EMPTY_CODE" = "422" ]; then
  pass "empty query -> http $EMPTY_CODE graceful rejection ($(($(now)-T))ms)"
elif [ "${EMPTY_CODE:0:1}" = "5" ]; then
  fail "empty query" "server error http $EMPTY_CODE"
else
  fail "empty query" "expected 4xx rejection, got http $EMPTY_CODE"
fi

# 6. HTML search ---------------------------------------------------------------
T=$(now)
HTML_HITS=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=ollama" | grep -c "result")
if [ -n "$HTML_HITS" ] && [ "$HTML_HITS" -gt 0 ]; then
  pass "search HTML page renders ($HTML_HITS result-markup matches, $(($(now)-T))ms)"
else
  fail "search HTML" "no result markup in page"
fi

# 7. Autocomplete --------------------------------------------------------------
T=$(now)
SUGGESTIONS=$(curl -sf --max-time 15 "$SEARXNG_HOST/autocompleter?q=ollama" | \
  json "import json,sys; d=json.load(sys.stdin); print(len(d[1]) if isinstance(d,list) and len(d)>1 else 0)")
if [ -n "$SUGGESTIONS" ] && [ "$SUGGESTIONS" -gt 0 ]; then
  pass "autocompleter -> $SUGGESTIONS suggestions ($(($(now)-T))ms)"
else
  fail "autocompleter" "no suggestions returned"
fi

# 8. Config endpoint -------------------------------------------------------------
T=$(now)
CFG_OK=$(curl -sf --max-time 10 "$SEARXNG_HOST/config" | \
  json "import json,sys; d=json.load(sys.stdin); print(d.get('autocomplete','') if d else '')")
if [ -n "$CFG_OK" ]; then
  pass "/config exposes instance config (autocomplete=$CFG_OK, $(($(now)-T))ms)"
else
  fail "/config" "no config JSON returned"
fi

# 9. OpenSearch descriptor --------------------------------------------------------
T=$(now)
OS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SEARXNG_HOST/opensearch.xml")
if [ "$OS_CODE" = "200" ]; then
  pass "/opensearch.xml -> http 200 (browser search integration, $(($(now)-T))ms)"
else
  fail "/opensearch.xml" "http $OS_CODE"
fi

# 10. Category filter (edge: categories=images) ------------------------------------
T=$(now)
IMG_COUNT=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=cats&format=json&categories=images" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
if [ -n "$IMG_COUNT" ] && [ "$IMG_COUNT" -gt 0 ]; then
  pass "categories=images -> $IMG_COUNT image results ($(($(now)-T))ms)"
else
  fail "categories=images" "no image results"
fi

# 11. Language filter (edge: language=de) -------------------------------------------
T=$(now)
DE_COUNT=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=wetter&format=json&language=de" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
if [ -n "$DE_COUNT" ] && [ "$DE_COUNT" -gt 0 ]; then
  pass "language=de -> $DE_COUNT results ($(($(now)-T))ms)"
else
  fail "language=de" "no results with language filter"
fi

# 12. Time-range filter (edge: time_range=day) ---------------------------------------
T=$(now)
TIME_COUNT=$(curl -sf --max-time 30 "$SEARXNG_HOST/search?q=news&format=json&time_range=day" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
if [ -n "$TIME_COUNT" ] && [ "$TIME_COUNT" -gt 0 ]; then
  pass "time_range=day -> $TIME_COUNT results ($(($(now)-T))ms)"
else
  fail "time_range=day" "no results with time filter"
fi

echo
echo "${B}SearXNG:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -eq 0 ]
