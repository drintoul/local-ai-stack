# 🚀 Local AI Stack (`local-ai-stack`)

An all-in-one, privacy-focused local LLM ecosystem powered by **Docker Compose**. This repository integrates **Ollama** for model inference, **SearXNG** for real-time web search capabilities, **Firecrawl** for web scraping/crawling (backed by headless **Playwright** Chromium), **Langfuse** for LLM observability/tracing, and automated tools for model provisioning and hardware benchmarking.

---

## 🏗 System Architecture & Directory Map

```text
.
├── .env                    # Environment variables, pinned versions & hardware tuning
├── .env.example            # Template for .env (safe defaults, no secrets)
├── docker-compose.yaml     # Orchestrates Ollama, SearXNG, Firecrawl, and Langfuse
├── ollama/                 # Ollama cache, model blobs, and configurations
├── searxng/                # SearXNG privacy-focused metasearch engine config
│   ├── limiter.toml        # SearXNG rate-limiting configuration
│   └── settings.yml        # Optimized SearXNG search & output settings for RAG
├── firecrawl/              # Firecrawl NuQ Postgres job-queue data (bind mount)
├── langfuse/               # Langfuse Postgres, ClickHouse, MinIO & Redis data
└── tests/                  # Automation, smoke tests, and benchmark tools
    ├── smoke_test.sh       # Runner: executes every per-service test script
    ├── test_ollama.sh      # Ollama API tests (gen, chat, stream, embed, tools, vision)
    ├── test_searxng.sh     # SearXNG tests (UI, JSON, filters, autocomplete, config)
    ├── test_firecrawl.sh   # Firecrawl tests (scrape, search, map, crawl, batch, edge cases)
    ├── test_playwright.sh  # Playwright tests (render, wait_after_load, SSRF guard, pool)
    ├── benchmark.sh        # Python/Bash benchmark suite (tok/s, peak VRAM, wall-time)
    └── pull_models.sh      # Script to pull tiered LLM, vision, and embedding models
```

---

## 🛠 Component Overview

| Service / Tool | Primary Purpose | Key Features |
| :--- | :--- | :--- |
| **Ollama** | Local Model Inference | Serves GGUF-quantized LLMs, vision, and embedding models via REST API (port `11434`). |
| **SearXNG** | Privacy Web Metasearch | Enables web search RAG for local agents without external tracking or rate-limits (port `8088`). |
| **Firecrawl** | Web Scrape/Crawl → Markdown | Converts any URL into clean LLM-ready markdown; also provides the SearXNG-backed `/search` endpoint (port `3002`). |
| **Playwright** | Headless Browser Renderer | Firecrawl's JS-rendering engine for dynamic sites; reachable on `llm-network` as `firecrawl-playwright:3000`. |
| **Langfuse** | LLM Observability & Tracing | Self-hosted LangSmith alternative — trace trees, token/latency/cost analytics, prompt management, evals (UI port `3000`). |
| **`.env`** | Versions & Hardware Tuning | Pinned image versions, Flash Attention, KV cache quantization, and model loading limits. |
| **`pull_models.sh`** | Automated Model Deployment | Downloads tier-categorized models (8GB vs 24GB VRAM, Vision, Embeddings). |
| **`benchmark.sh`** | Hardware Benchmarking | Measures prompt processing speed, generation throughput (tok/s), and GPU VRAM footprint. |

---

## 🚦 Quick Start Guide

### 1. Prerequisites
* **OS:** Linux (Ubuntu/Debian recommended) or macOS with Docker installed.
* **GPU (Recommended):** NVIDIA GPU with CUDA drivers (optimized for 24 GB VRAM / RTX 3090) and [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) configured for Docker access.
* **Storage:** At least 50–100 GB of free space depending on the number of models pulled.

### 2. Launch the Stack
Start all services in detached mode using Docker Compose:

```bash
docker compose up -d
```

Verify that all containers are healthy:

```bash
docker compose ps
```

---

## 📦 Model Management (`tests/pull_models.sh`)

The `pull_models.sh` script automates downloading a curated list of high-performance models categorized by hardware tier:

* **Tier 1 (24 GB VRAM Heavyweights):** `deepseek-r1:32b`, `qwen2.5:32b`, `qwen2.5-coder:32b`, `gemma2:27b`.
* **Tier 2 (Midweights / Math):** `phi4`, `mistral-nemo`, `deepseek-coder-v2:16b`.
* **Tier 3 (8 GB VRAM Sweet Spot):** `deepseek-r1:8b`, `qwen2.5:7b`, `llama3.1:8b`, `command-r7b`, `aya-expanse`.
* **Tier 4 (Low Latency Agents):** `llama3.2:3b`.
* **Tier 5 (Vision / Multimodal):** `llama3.2-vision`, `qwen2.5vl`, `minicpm-v`.
* **Tier 6 (Embeddings for RAG):** `nomic-embed-text`, `bge-m3`, `mxbai-embed-large`.

### Running the Pull Script

```bash
# Make executable (first time only)
chmod +x tests/pull_models.sh

# Execute the model pull sequence
./tests/pull_models.sh
```

> **Note:** To pull models into a custom container name, pass `CONTAINER_NAME="my-ollama" ./tests/pull_models.sh`.

---

## 📊 Performance Benchmarking (`tests/benchmark.sh`)

The `benchmark.sh` script tests installed models against a standardized reasoning and coding prompt. It measures prompt ingestion speed, token generation output, peak GPU VRAM usage via `nvidia-smi`, and total execution time.

### Running a Benchmark

```bash
# Make executable (first time only)
chmod +x tests/benchmark.sh

# Run interactive benchmark suite
./tests/benchmark.sh
```

### Output Example
```text
=============================================================================================
 📊 BATCH BENCHMARK COMPARISON TABLE
=============================================================================================
Model Name                     | Quant    | Prompt tok/s | Gen tok/s  | Peak VRAM  | Wall Time 
---------------------------------------------------------------------------------------------
qwen2.5:7b                     | Q4_K_M   |       1840.2 |       84.5 | 4.82 GB    |     5.12s
deepseek-r1:8b                 | Q4_K_M   |       1620.1 |       62.3 | 5.10 GB    |     8.45s
=============================================================================================
```

---

## ⚙️ Configuration Details

### Environment & VRAM Tuning (`.env`)
The `.env` file is pre-configured for high-throughput local inference on 24 GB VRAM GPUs (e.g., NVIDIA RTX 3090):

* **`OLLAMA_FLASH_ATTENTION=1`:** Enables Flash Attention on Ampere architectures to significantly boost speed and reduce memory consumption.
* **`OLLAMA_KV_CACHE_TYPE=q8_0`:** Quantizes the key-value context cache from 16-bit float (`f16`) to 8-bit (`q8_0`), saving ~50% KV VRAM and allowing larger context windows.
* **`OLLAMA_MAX_LOADED_MODELS=2`:** Allows a primary generation model and a smaller embedding model to remain warm in GPU memory simultaneously.
* **`OLLAMA_KEEP_ALIVE=-1`:** Keeps models resident in GPU VRAM indefinitely to prevent reload delays during active sessions.
* **`OLLAMA_CONTEXT_LENGTH=8192`:** Sets default context window size across served models.

### SearXNG Configuration (`searxng/settings.yml`)
* **JSON API Enabled:** Allows Firecrawl and custom Python agents to query search results programmatically.
* **Aggressive Timeouts:** `request_timeout: 2.5s` ensures slow web search engines do not hang LLM agent responses.
* **Rate Limiting Disabled:** `limiter: false` allows rapid internal API queries between local containers.

### Firecrawl Stack
Firecrawl runs as five containers: the **API/worker** (`firecrawl`, port `3002`), **Playwright** renderer, and an internal queue backend (**Redis**, **RabbitMQ**, **NuQ Postgres**) on a private `firecrawl-internal` network with no host ports. The API is dual-homed on `llm-network`, so it can reach `searxng:8080` and `ollama:11434` directly.

* **Queue admin UI:** `http://localhost:3002/admin/<FIRECRAWL_BULL_AUTH_KEY>/queues` (key is set in `.env`).
* **Version pinning:** `firecrawl` is pinned to a release tag; `playwright-service` and `nuq-postgres` publish only mutable tags on GHCR, so they are pinned by content digest in `.env`.
* **Test a scrape:**
  ```bash
  curl -X POST http://localhost:3002/v1/scrape \
    -H 'Content-Type: application/json' \
    -d '{"url": "https://example.com"}'
  ```

### Langfuse Stack
Langfuse runs as six containers: **web** (`langfuse-web`, port `3000`) and **worker** (`langfuse-worker`) on `llm-network` so they can reach `ollama:11434` for LLM-assisted evals, plus an internal backend (**Postgres**, **ClickHouse**, **MinIO**, **Redis**) on the private `langfuse-internal` network. MinIO also publishes port `9090` for browser-side media uploads.

* **Web UI:** `http://localhost:3000` — sign in with `LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD` from `.env`.
* **Pre-provisioned:** org `Local AI Stack`, project `local`, and API keys (`LANGFUSE_INIT_PUBLIC_KEY` / `LANGFUSE_INIT_SECRET_KEY`) are created on first boot — no manual project setup needed.
* **Images:** pulled from `docker.langfuse.com` (official v4 registry) and `cgr.dev/chainguard` (MinIO, since it left Docker Hub).
* **Send a test trace:**
  ```bash
  curl -X POST http://localhost:3000/api/public/ingestion \
    -u "$LANGFUSE_INIT_PUBLIC_KEY:$LANGFUSE_INIT_SECRET_KEY" \
    -H 'Content-Type: application/json' \
    -d '{"batch":[{"id":"t1","type":"trace-create","timestamp":"'"$(date -u +%FT%TZ)"'","body":{"id":"my-first-trace","name":"hello-langfuse"}}]}'
  ```

---

## 🔒 Security & Maintenance Notes

> [!WARNING]
> Ensure you change the default `secret_key` inside `searxng/settings.yml` before exposing any service to a public network:
> ```bash
> openssl rand -hex 32
> ```

* **Updating Services:** To pull the latest Docker image updates:
  ```bash
  docker compose pull && docker compose up -d
  ```
* **Monitoring Logs:** View real-time container output:
  ```bash
  docker compose logs -f
  ```
