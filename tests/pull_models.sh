#!/usr/bin/env bash

# ==============================================================================
# OLLAMA MODEL PULL AUTOMATION SCRIPT
# ==============================================================================
# Description:
#   Automates pulling a curated set of LLM, Vision, and Embedding models into a
#   running Ollama Docker container. Models are categorized by GPU VRAM
#   requirements and operational domain.
#
# Prerequisites:
#   - Docker daemon running.
#   - Ollama container active and reachable.
#
# Environment Variables:
#   CONTAINER_NAME - Override default container name (Default: "ollama")
#
# Usage:
#   ./pull_models.sh
#   CONTAINER_NAME="my-ollama-container" ./pull_models.sh
# ==============================================================================

# Clear screen at start
clear

# Configurable container name (defaults to "ollama" if CONTAINER_NAME is unset)
CONTAINER_NAME="${CONTAINER_NAME:-ollama}"

# ------------------------------------------------------------------------------
# Pre-Flight Checks
# ------------------------------------------------------------------------------
# 1. Verify Docker CLI exists
if ! command -v docker &> /dev/null; then
    echo "❌ Error: 'docker' CLI command not found. Please install Docker." >&2
    exit 1
fi

# 2. Verify target container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ Error: Docker container '${CONTAINER_NAME}' is not running or does not exist." >&2
    echo "   Ensure your container is active or set CONTAINER_NAME correctly." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# List of models to pull into Ollama
# Mirrors the models actually installed on this stack (verified via /api/tags).
# Tags sharing a digest are aliases — pulling both reproduces the tag set
# exactly; the second pull only writes a manifest and downloads nothing.
# Grouped by size tier.
# ------------------------------------------------------------------------------
MODELS=(
    # --- Tier 1: Heavyweights (24B–32B, saturates 24 GB VRAM) ---
    "qwen2.5:32b-instruct"           # 32B generalist & JSON/structured output (~19.9 GB)
    "qwen2.5:32b-instruct-q4_K_M"    # alias of qwen2.5:32b-instruct (same digest)
    "qwen3.8:27b-q4_K_M"             # 27B q4_K_M quant (~17.7 GB)
    "mistral-small3.1:24b"           # 24B Mistral small (~15.5 GB)

    # --- Tier 2: Midweights (12B–16B) ---
    "qwen3:14b"                      # 14B Qwen3 reasoning (~9.3 GB)
    "phi4:14b"                       # 14B math/logic powerhouse (~9.1 GB)
    "phi4:latest"                    # alias of phi4:14b (same digest)
    "qwen2.5:14b"                    # 14B Qwen2.5 generalist (~9.0 GB)
    "deepseek-r1:14b"                # 14B distilled reasoning (~9.0 GB)
    "deepseek-coder-v2:16b"          # 16B sparse MoE coding baseline (~8.9 GB)
    "gemma3:12b"                     # 12B Gemma3, also multimodal (~8.1 GB)
    "mistral-nemo:latest"            # 12B 128k-context instruction model (~7.1 GB)

    # --- Tier 3: 8 GB VRAM Sweet Spot (7B–9B) ---
    "qwen2.5:7b-instruct-q8_0"       # 7B q8_0 quant (~8.1 GB)
    "qwen3:8b"                       # 8B Qwen3 (~5.2 GB)
    "command-r7b:latest"             # 7B Cohere, RAG/tool workflows (~5.1 GB)
    "aya-expanse:latest"             # 8B Cohere multilingual (~5.1 GB)
    "granite3-dense:8b"              # 8B IBM tool use & structured RAG (~4.9 GB)
    "llama3.1:8b"                    # 8B Meta generalist & tool calling (~4.9 GB)
    "llama3.1:latest"                # alias of llama3.1:8b (same digest)
    "qwen2.5-coder:7b"               # 7B coding assistant (~4.7 GB)

    # --- Tier 4: Ultra-Fast / Low-Latency Sub-Agents (<4B) ---
    "llama3.2:latest"                # 3B sub-agent & routing baseline (~2.0 GB)

    # --- Tier 5: Vision & Multimodal ---
    # NOTE: llama3.2-vision uses 'mllama' arch, unsupported by Ollama 0.40.x.
    #       gemma3:12b (Tier 2) is the primary multimodal model.
    "qwen2.5vl:latest"               # Document, UI screenshot & diagram parser (~6.0 GB)

    # --- Tier 6: Embeddings for RAG ---
    "bge-m3:latest"                  # Multilingual dense/sparse retrieval (~1.2 GB)
    "mxbai-embed-large:latest"       # High-accuracy document retrieval (~0.7 GB)
    "nomic-embed-text:latest"        # Fast dense embeddings (~0.3 GB)
)

# Determine TTY flag: Use -it for interactive terminals, -i for non-interactive/cron environments
if [ -t 0 ]; then
    DOCKER_FLAGS="-it"
else
    DOCKER_FLAGS="-i"
fi

echo "=================================================="
echo "🚀 Starting model pulls for container: '$CONTAINER_NAME'"
echo "=================================================="

# Track statistics
SUCCESS_COUNT=0
FAILED_COUNT=0
FAILED_MODELS=()

for model in "${MODELS[@]}"; do
    echo ""
    echo "⬇️  Pulling model: $model"
    echo "--------------------------------------------------"

    if docker exec $DOCKER_FLAGS "$CONTAINER_NAME" ollama pull "$model"; then
        echo "✓ Successfully pulled: $model"
        ((SUCCESS_COUNT++))
    else
        echo "❌ Failed to pull: $model"
        ((FAILED_COUNT++))
        FAILED_MODELS+=("$model")
    fi
done

echo ""
echo "=================================================="
echo "🎉 Model pull sequence completed!"
echo "   • Successfully pulled: $SUCCESS_COUNT"
echo "   • Failed:              $FAILED_COUNT"

if [ ${#FAILED_MODELS[@]} -gt 0 ]; then
    echo "--------------------------------------------------"
    echo "⚠️ Failed models:"
    for failed_model in "${FAILED_MODELS[@]}"; do
        echo "   - $failed_model"
    done
fi
echo "=================================================="
