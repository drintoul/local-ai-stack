#!/usr/bin/env bash

# ==============================================================================
# LOCAL AI STACK SMOKE TEST (RUNNER)
# ==============================================================================
# Description:
#   Runs every per-service test script in this directory and reports an
#   overall result. Each script can also be run standalone.
#
# Prerequisites:
#   - curl, python3, docker
#   - docker compose stack running (docker compose up -d)
#
# Environment Variables:
#   Passed through to the individual scripts:
#   OLLAMA_HOST, SEARXNG_HOST, FIRECRAWL_HOST, GEN_MODEL, EMBED_MODEL,
#   CRAWL_TIMEOUT, PW_CONTAINER, EXEC_CONTAINER
#
# Usage:
#   ./smoke_test.sh                 # run everything
#   ./test_ollama.sh                # just one service
# ==============================================================================

cd "$(dirname "$0")" || exit 1

# Tell sub-scripts not to clear the screen between suites
export SMOKE_RUNNER=1
[ -t 1 ] && clear

if [ -t 1 ]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; B=""; N=""
fi

FAILED_SCRIPTS=0

echo "${B}=================================================="
echo "  LOCAL AI STACK - SMOKE TEST SUITE"
echo "==================================================${N}"

for script in test_ollama.sh test_searxng.sh test_firecrawl.sh test_playwright.sh; do
  echo
  bash "./$script"
  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    FAILED_SCRIPTS=$((FAILED_SCRIPTS + 1))
  fi
done

echo
echo "${B}==================================================${N}"
if [ "$FAILED_SCRIPTS" -eq 0 ]; then
  echo "  ${G}✓ ALL SUITES PASSED${N}"
else
  echo "  ${R}✗ $FAILED_SCRIPTS suite(s) had failures${N}"
fi
echo "${B}==================================================${N}"

[ "$FAILED_SCRIPTS" -eq 0 ]
