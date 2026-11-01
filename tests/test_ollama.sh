#!/usr/bin/env bash

# ==============================================================================
# OLLAMA CONTAINER TESTS
# ==============================================================================
# Description:
#   Verbose health/functionality tests for the Ollama service, including
#   edge cases: version, catalog, generation, streaming, chat, loaded-model
#   state, single + batch embeddings, and invalid-model rejection.
#   Each check reports wall-clock time and response details.
#
# Prerequisites:
#   - curl, python3
#   - Ollama running and reachable
#
# Environment Variables:
#   OLLAMA_HOST   Default: http://localhost:11434
#   GEN_MODEL     Generation/chat model   (default: llama3.2:latest)
#   EMBED_MODEL   Embeddings model        (default: nomic-embed-text:latest)
#
# Usage:
#   ./test_ollama.sh
#   GEN_MODEL="qwen3:8b" ./test_ollama.sh
# ==============================================================================

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
GEN_MODEL="${GEN_MODEL:-llama3.2:latest}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
TOOL_MODEL="${TOOL_MODEL:-llama3.1:8b}"
# llama3.2-vision uses the 'mllama' architecture, unsupported by Ollama's
# bundled runner (0.40.x). gemma3:12b is the installed multimodal alternative.
VISION_MODEL="${VISION_MODEL:-gemma3:12b}"

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

echo "${B}== Ollama ($OLLAMA_HOST) ==${N}"

# 1. Version -------------------------------------------------------------------
T=$(now)
VER=$(curl -sf --max-time 10 "$OLLAMA_HOST/api/version" | \
  json "import json,sys; print(json.load(sys.stdin).get('version',''))")
if [ -n "$VER" ]; then
  pass "api/version reports v$VER ($(($(now)-T))ms)"
else
  fail "api/version" "no version returned"
fi

# 2. Model catalog -------------------------------------------------------------
T=$(now)
TAG_INFO=$(curl -sf --max-time 10 "$OLLAMA_HOST/api/tags" | \
  json "import json,sys; ms=json.load(sys.stdin).get('models',[]); print(len(ms), sum(1 for m in ms if m.get('name') and m.get('size',0)>0))")
MODEL_COUNT=$(echo "$TAG_INFO" | cut -d' ' -f1)
VALID_COUNT=$(echo "$TAG_INFO" | cut -d' ' -f2)
if [ -n "$MODEL_COUNT" ] && [ "$MODEL_COUNT" -gt 0 ] && [ "$MODEL_COUNT" = "$VALID_COUNT" ]; then
  pass "api/tags returns $MODEL_COUNT models, all well-formed ($(($(now)-T))ms)"
elif [ -n "$MODEL_COUNT" ] && [ "$MODEL_COUNT" -gt 0 ]; then
  fail "api/tags" "$((MODEL_COUNT-VALID_COUNT)) of $MODEL_COUNT entries malformed"
else
  fail "api/tags" "no response or empty catalog"
fi

# 3. Raw generation (with token metrics) ----------------------------------------
T=$(now)
GEN_JSON=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/generate" \
  -d "{\"model\":\"$GEN_MODEL\",\"prompt\":\"Reply with exactly: OK\",\"stream\":false}")
GEN_INFO=$(echo "$GEN_JSON" | json "
import json,sys; d=json.load(sys.stdin)
r=d.get('response','').strip()
ec=d.get('eval_count',0); ed=d.get('eval_duration',1)
print(' '.join([r.replace(' ','_')[:40], str(ec), str(round(ec/max(ed/1e9,0.001),1))]))")
GEN_RESP=$(echo "$GEN_INFO" | cut -d' ' -f1 | tr '_' ' ')
GEN_TOKS=$(echo "$GEN_INFO" | cut -d' ' -f2)
GEN_TPS=$(echo "$GEN_INFO" | cut -d' ' -f3)
if echo "$GEN_RESP" | grep -qw "OK"; then
  pass "api/generate ($GEN_MODEL) -> \"$GEN_RESP\" [$GEN_TOKS tok @ ${GEN_TPS} tok/s, $(($(now)-T))ms]"
else
  fail "api/generate" "no 'OK' in response: ${GEN_RESP:-<no response>}"
fi

# 4. Streaming generation (edge: NDJSON stream terminates with done) ------------
T=$(now)
STREAM_INFO=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/generate" \
  -d "{\"model\":\"$GEN_MODEL\",\"prompt\":\"Say OK\",\"stream\":true}" | \
  json "
import json,sys
lines=[l for l in sys.stdin if l.strip()]
try:
    last=json.loads(lines[-1])
    print(len(lines), last.get('done'))
except Exception:
    print(len(lines), 'parse_error')")
STREAM_CHUNKS=$(echo "$STREAM_INFO" | cut -d' ' -f1)
STREAM_DONE=$(echo "$STREAM_INFO" | cut -d' ' -f2)
if [ "$STREAM_DONE" = "True" ] && [ "${STREAM_CHUNKS:-0}" -gt 1 ]; then
  pass "api/generate stream=true emits $STREAM_CHUNKS chunks ending done=true ($(($(now)-T))ms)"
else
  fail "api/generate stream" "chunks=$STREAM_CHUNKS done=$STREAM_DONE"
fi

# 5. Chat completions ----------------------------------------------------------
T=$(now)
CHAT_RESP=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/chat" \
  -d "{\"model\":\"$GEN_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"stream\":false}" | \
  json "import json,sys; print(json.load(sys.stdin).get('message',{}).get('content','').strip())")
if echo "$CHAT_RESP" | grep -qw "OK"; then
  pass "api/chat ($GEN_MODEL) -> \"$(echo "$CHAT_RESP" | head -c 60)\" ($(($(now)-T))ms)"
else
  fail "api/chat" "no 'OK' in response: ${CHAT_RESP:-<no response>}"
fi

# 6. Loaded model state --------------------------------------------------------
# Check BEFORE embeddings: OLLAMA_MAX_LOADED_MODELS=2 means loading the
# embed model below can evict GEN_MODEL from memory.
T=$(now)
LOADED=$(curl -sf --max-time 10 "$OLLAMA_HOST/api/ps" | \
  json "import json,sys; print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))")
if echo "$LOADED" | grep -q "${GEN_MODEL%%:*}"; then
  pass "api/ps loaded: [$LOADED] ($(($(now)-T))ms)"
else
  fail "api/ps" "expected $GEN_MODEL loaded, got: ${LOADED:-<none>}"
fi

# 7. Embeddings ----------------------------------------------------------------
T=$(now)
EMBED_DIMS=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/embeddings" \
  -d "{\"model\":\"$EMBED_MODEL\",\"prompt\":\"hello world\"}" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('embedding',[])))")
if [ -n "$EMBED_DIMS" ] && [ "$EMBED_DIMS" -gt 0 ]; then
  pass "api/embeddings ($EMBED_MODEL) -> ${EMBED_DIMS}-dim vector ($(($(now)-T))ms)"
else
  fail "api/embeddings" "no embedding vector returned"
fi

# 8. Batch embeddings (edge: array input on /api/embed) -------------------------
T=$(now)
BATCH_N=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/embed" \
  -d "{\"model\":\"$EMBED_MODEL\",\"input\":[\"alpha\",\"beta\",\"gamma\"]}" | \
  json "import json,sys; print(len(json.load(sys.stdin).get('embeddings',[])))")
if [ "$BATCH_N" = "3" ]; then
  pass "api/embed batch input -> 3 vectors ($(($(now)-T))ms)"
else
  fail "api/embed batch" "expected 3 vectors, got: ${BATCH_N:-<none>}"
fi

# 9. Invalid model rejection (edge: graceful 404) --------------------------------
T=$(now)
ERR_RESP=$(curl -s -w '|%{http_code}' --max-time 10 "$OLLAMA_HOST/api/generate" \
  -d '{"model":"definitely-not-a-real-model:9b","prompt":"hi","stream":false}')
ERR_CODE=${ERR_RESP##*|}
ERR_MSG=$(echo "${ERR_RESP%|*}" | json "import json,sys; print(json.load(sys.stdin).get('error',''))")
if [ "$ERR_CODE" = "404" ] && echo "$ERR_MSG" | grep -q "not found"; then
  pass "invalid model -> 404 \"$ERR_MSG\" ($(($(now)-T))ms)"
else
  fail "invalid model" "expected 404+error, got http $ERR_CODE: $ERR_MSG"
fi

# 10. Model metadata ------------------------------------------------------------
T=$(now)
SHOW_INFO=$(curl -sf --max-time 10 "$OLLAMA_HOST/api/show" \
  -d "{\"name\":\"$GEN_MODEL\"}" | \
  json "import json,sys; d=json.load(sys.stdin); det=d.get('details',{}); print(det.get('family',''), det.get('parameter_size',''), det.get('quantization_level',''))")
if [ -n "$(echo "$SHOW_INFO" | tr -d ' ')" ]; then
  pass "api/show ($GEN_MODEL) -> family=$(echo "$SHOW_INFO" | cut -d' ' -f1) params=$(echo "$SHOW_INFO" | cut -d' ' -f2) quant=$(echo "$SHOW_INFO" | cut -d' ' -f3) ($(($(now)-T))ms)"
else
  fail "api/show" "no model details returned"
fi

# 11. Structured JSON output (edge: format=json produces parseable JSON) --------
T=$(now)
JSON_OK=$(curl -sf --max-time 120 "$OLLAMA_HOST/api/generate" \
  -d "{\"model\":\"$GEN_MODEL\",\"prompt\":\"Output JSON with key ok set to true\",\"format\":\"json\",\"stream\":false}" | \
  json "
import json,sys
try:
    r=json.load(sys.stdin).get('response','')
    json.loads(r); print('ok')
except Exception:
    print('bad')")
if [ "$JSON_OK" = "ok" ]; then
  pass "format:json -> valid parseable JSON response ($(($(now)-T))ms)"
else
  fail "format:json" "response was not valid JSON"
fi

# 12. Tool calling (edge: function-call schema) -----------------------------------
# temperature:0 + a directive prompt keeps this deterministic -- the model
# otherwise sometimes answers directly instead of calling the tool.
T=$(now)
TOOL_CALLS=$(curl -sf --max-time 180 "$OLLAMA_HOST/api/chat" \
  -d "{\"model\":\"$TOOL_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Use the get_weather tool to check the weather in Paris.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather for a city\",\"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],\"options\":{\"temperature\":0},\"stream\":false}" | \
  json "import json,sys; tc=json.load(sys.stdin).get('message',{}).get('tool_calls',[]); print(len(tc), tc[0]['function']['name'] if tc else '')")
TOOL_N=$(echo "$TOOL_CALLS" | cut -d' ' -f1)
TOOL_FN=$(echo "$TOOL_CALLS" | cut -d' ' -f2)
if [ "${TOOL_N:-0}" -gt 0 ] 2>/dev/null; then
  pass "tool calling ($TOOL_MODEL) -> $TOOL_N call(s): $TOOL_FN ($(($(now)-T))ms)"
else
  fail "tool calling" "no tool_calls in response"
fi

# 13. Vision input (edge: multimodal image prompt) --------------------------------
# Note: surfaces the server error on failure (e.g. unsupported model
# architecture on older Ollama builds).
T=$(now)
VISION_OUT=$(curl -s --max-time 180 "$OLLAMA_HOST/api/generate" \
  -d "{\"model\":\"$VISION_MODEL\",\"prompt\":\"Describe this image in one word\",\"images\":[\"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==\"],\"stream\":false}")
VISION_RESP=$(echo "$VISION_OUT" | json "import json,sys; print(json.load(sys.stdin).get('response','').strip()[:60].replace(' ','_'))")
VISION_ERR=$(echo "$VISION_OUT" | json "import json,sys; print(json.load(sys.stdin).get('error','')[:120])")
if [ -n "$VISION_RESP" ]; then
  pass "vision input ($VISION_MODEL) -> \"$(echo "$VISION_RESP" | tr '_' ' ')\" ($(($(now)-T))ms)"
else
  fail "vision input ($VISION_MODEL)" "${VISION_ERR:-no response for image prompt}"
fi

echo
echo "${B}Ollama:${N} ${G}$PASS passed${N}, ${R}$FAIL failed${N}, ${Y}$SKIP skipped${N}"
[ "$FAIL" -eq 0 ]
