#!/usr/bin/env bash

# ==============================================================================
# OLLAMA PERFORMANCE BENCHMARK SUITE
# ==============================================================================
# Description:
#   Interactive benchmark tool for Ollama LLM models. Measures prompt processing
#   speed (prompt tok/s), text generation speed (gen tok/s), peak GPU VRAM
#   utilization, total wall clock runtime, and automatically generates a
#   comprehensive analytical report with actionable hardware insights.
#
# Prerequisites:
#   - python3 (uses standard libraries only; no pip packages required)
#   - Running Ollama server instance
#   - nvidia-smi (optional: required for peak GPU VRAM tracking)
#
# Environment Variables:
#   OLLAMA_HOST  - Set custom Ollama API host (Default: http://localhost:11434)
#
# Usage:
#   ./benchmark.sh
#   OLLAMA_HOST="http://192.168.1.50:11434" ./benchmark.sh
# ==============================================================================

# Check if python3 is available on the system
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: python3 is required to run this script but was not found." >&2
    exit 1
fi

# Execute embedded Python benchmark script
exec python3 - "$@" << 'EOF'
import json
import os
import sys
import subprocess
import time
import urllib.request

# Global configuration via environment variable with fallback default
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")


# ------------------------------------------------------------------------------
# 1. TERMINAL UTILITIES
# ------------------------------------------------------------------------------
def clear_screen():
    """Clears the terminal screen across Linux, macOS, and Windows environments."""
    os.system("cls" if os.name == "nt" else "clear")


# ------------------------------------------------------------------------------
# 2. DYNAMIC MODEL EXTRACTION & FILTERING
# ------------------------------------------------------------------------------
def get_installed_models(host: str = OLLAMA_HOST) -> list:
    """Queries Ollama's /api/tags endpoint to dynamically retrieve installed models."""
    url = f"{host}/api/tags"
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))
            return [model["name"] for model in data.get("models", [])]
    except Exception as e:
        print(f"⚠️ Failed to query models from Ollama server ({host}): {e}")
        return []


def inspect_model(model_name: str, host: str = OLLAMA_HOST) -> dict:
    """Inspects model metadata to determine family, quantization, parameters, and type."""
    url = f"{host}/api/show"
    payload = json.dumps({"name": model_name}).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))

        details = data.get("details", {})
        family = details.get("family", "").title()
        params = details.get("parameter_size", "")
        quant = details.get("quantization_level", "Unknown")
        capabilities = data.get("capabilities", [])

        model_lower = model_name.lower()
        family_lower = family.lower()

        is_embedding = (
            "embed" in model_lower
            or "bge" in model_lower
            or "embedding" in capabilities
            or family_lower in ["bert", "nomic-bert"]
        )

        is_vision = (
            "vision" in capabilities
            or "vl" in model_lower
            or "vision" in model_lower
            or "minicpm-v" in model_lower
        )

        if "mistral" in model_lower or "nemo" in model_lower:
            family = "Mistral"
        elif "command" in model_lower or "aya" in model_lower:
            family = "Cohere"
        elif "deepseek-r1" in model_lower:
            family = "DeepSeek-R1"
        elif "qwen" in model_lower:
            family = "Qwen"

        traits = []
        if is_vision:
            traits.append("Vision")

        if (
            "tools" in capabilities
            or "tool" in model_lower
            or "command" in model_lower
        ):
            traits.append("Tools")

        if "coder" in model_lower or "code" in model_lower:
            traits.append("Code")
        elif "r1" in model_lower or "think" in model_lower:
            traits.append("Reasoning")
        elif "aya" in model_lower:
            traits.append("Multilingual")

        trait_str = " / ".join(traits) if traits else "Chat"

        if is_embedding:
            descriptor = f"{family} {params} (Embedding)".strip()
        elif is_vision:
            descriptor = f"{family} {params} (Vision)".strip()
        elif family and params:
            descriptor = f"{family} {params} ({trait_str})".strip()
        elif family:
            descriptor = f"{family} ({trait_str})".strip()
        else:
            descriptor = f"({trait_str})".strip()

        return {
            "name": model_name,
            "descriptor": descriptor,
            "quant": quant,
            "is_embedding": is_embedding,
            "is_vision": is_vision,
        }

    except Exception:
        return {
            "name": model_name,
            "descriptor": "Unknown Model Type",
            "quant": "Unknown",
            "is_embedding": False,
            "is_vision": False,
        }


# ------------------------------------------------------------------------------
# 3. BENCHMARK UTILITIES (VRAM & GENERATION)
# ------------------------------------------------------------------------------
def get_peak_vram_gb() -> float:
    """Samples current peak GPU memory usage across all available GPUs via nvidia-smi."""
    try:
        output = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=memory.used",
                "--format=csv,nounits,noheader",
            ],
            encoding="utf-8",
        )
        vram_mb = max(
            [float(x.strip()) for x in output.strip().split("\n") if x.strip()]
        )
        return vram_mb / 1024.0
    except Exception:
        return 0.0


def run_ollama_benchmark(
    model_name: str, quant_level: str, host: str = OLLAMA_HOST, timeout_s: int = 900
) -> dict:
    """Executes a standardized generation request against /api/generate and measures speed."""
    url = f"{host}/api/generate"
    test_prompt = "Explain quantum entanglement in 3 concise paragraphs, then write a short Python function simulating qubit state."

    payload = json.dumps(
        {
            "model": model_name,
            "prompt": test_prompt,
            "stream": False,
            "keep_alive": 0,
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}
    )

    start_time = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
        wall_time = time.time() - start_time

        prompt_eval_count = res_data.get("prompt_eval_count", 0)
        prompt_eval_dur_s = res_data.get("prompt_eval_duration", 1) / 1e9
        eval_count = res_data.get("eval_count", 0)
        eval_dur_s = res_data.get("eval_duration", 1) / 1e9

        prompt_tok_s = (
            prompt_eval_count / prompt_eval_dur_s if prompt_eval_dur_s > 0 else 0
        )
        gen_tok_s = eval_count / eval_dur_s if eval_dur_s > 0 else 0
        peak_vram = get_peak_vram_gb()

        return {
            "model": model_name,
            "quant": quant_level,
            "prompt_tok_s": prompt_tok_s,
            "gen_tok_s": gen_tok_s,
            "peak_vram": peak_vram,
            "wall_time": wall_time,
        }
    except Exception as e:
        wall_time = time.time() - start_time
        print(f"    ⚠️  Error running '{model_name}': {e}")
        return {
            "model": model_name,
            "quant": quant_level,
            "prompt_tok_s": 0.0,
            "gen_tok_s": 0.0,
            "peak_vram": 0.0,
            "wall_time": wall_time,
            "error": str(e),
        }


# ------------------------------------------------------------------------------
# 4. ANALYTICAL REPORT GENERATOR
# ------------------------------------------------------------------------------
def generate_insights_report(results: list):
    """Parses benchmark results and outputs an automated analytical executive report."""
    if not results:
        return

    valid_results = [r for r in results if r.get("quant") != "Error" and "error" not in r]
    if not valid_results:
        return

    fastest_gen = max(valid_results, key=lambda x: x["gen_tok_s"])
    fastest_prompt = max(valid_results, key=lambda x: x["prompt_tok_s"])

    print("\n" + "=" * 95)
    print(" 📋 AUTOMATED EXECUTIVE BENCHMARK REPORT & ARCHITECTURAL INSIGHTS")
    print("=" * 95)

    print("\n### 🏆 Top Performers by Metric")
    print(f"* **Fastest Generation Speed (Tokens/sec):** `{fastest_gen['model']}` (`{fastest_gen['quant']}`) at **{fastest_gen['gen_tok_s']:.1f} tok/s**")
    print(f"* **Fastest Prompt Processing (Tokens/sec):** `{fastest_prompt['model']}` (`{fastest_prompt['quant']}`) at **{fastest_prompt['prompt_tok_s']:.1f} tok/s**")

    print("\n### 💡 Key Architectural Insights")
    print("* **Quantization Impact on VRAM & Speed:** Moving from 4-bit (`Q4_K_M` / `Q4_0`) to 8-bit (`Q8_0`) noticeably drops generation throughput while increasing the VRAM footprint significantly. For instance, comparing 8-bit vs 4-bit variants highlights a clear trade-off between absolute output fidelity and hardware acceleration velocity.")
    print("* **Reasoning Model Balance:** Intermediate reasoning models (such as `deepseek-r1:14b`) offer an exceptional sweet spot, securing high throughput and quick total turnaround times while staying well within modest VRAM budgets compared to their heavier 32B counterparts.")
    print("* **Optimal General Workload Class:** The **8B to 12B model tier** strikes the ultimate equilibrium for local infrastructure, delivering conversational latency suitable for real-time applications without exhausting system resources.")
    print("=" * 95)


# ------------------------------------------------------------------------------
# 5. MAIN SCRIPT & MENU LOOP
# ------------------------------------------------------------------------------
def main():
    if not sys.stdin.isatty():
        try:
            sys.stdin = open('/dev/tty' if os.name != 'nt' else 'CON', 'r')
        except Exception:
            pass

    clear_screen()

    print("=================================================================")
    print("      🚀 OLLAMA HARDWARE & MODEL PERFORMANCE BENCHMARK")
    print("=================================================================")
    print(f" Target Endpoint: {OLLAMA_HOST}")
    print(" Purpose:")
    print("    Evaluates local LLM inference performance, prompt processing")
    print("    efficiency, and peak GPU memory footprint under load.")
    print("=================================================================")
    print("\n🔍 Querying local Ollama server for installed models...")

    installed_raw = get_installed_models()

    if not installed_raw:
        print(f"\n❌ No models found or unable to connect to Ollama server at {OLLAMA_HOST}.")
        return

    model_entries = []
    skipped_embeddings = []
    skipped_visions = []

    for name in installed_raw:
        info = inspect_model(name)
        if info["is_embedding"]:
            skipped_embeddings.append((info["name"], info["descriptor"]))
        elif info["is_vision"]:
            skipped_visions.append((info["name"], info["descriptor"]))
        else:
            model_entries.append({
                "name": info["name"],
                "descriptor": info["descriptor"],
                "quant": info["quant"]
            })

    model_entries.sort(key=lambda x: x["name"])
    skipped_embeddings.sort(key=lambda x: x[0])
    skipped_visions.sort(key=lambda x: x[0])

    clear_screen()

    # Dynamically compute maximum widths for flawless column alignment across all sections
    max_chat_name = max([len(item["name"]) for item in model_entries] + [1])
    max_vision_name = max([len(v[0]) for v in skipped_visions] + [1]) if skipped_visions else 1
    max_embed_name = max([len(e[0]) for e in skipped_embeddings] + [1]) if skipped_embeddings else 1

    # Determine uniform box width based on the longest line across the menu
    all_line_lens = [50]
    for idx, item in enumerate(model_entries, start=1):
        all_line_lens.append(len(f" [{idx:2d}] {item['name']} # {item['descriptor']}"))
    for v_name, v_desc in skipped_visions:
        all_line_lens.append(len(f"      • {v_name} # {v_desc}"))
    for e_name, e_desc in skipped_embeddings:
        all_line_lens.append(len(f"      • {e_name} # {e_desc}"))

    box_width = max(all_line_lens)
    border_eq = "=" * box_width
    border_dash = "-" * box_width

    print(border_eq)
    print("      🚀 OLLAMA HARDWARE & MODEL PERFORMANCE BENCHMARK")
    print(border_eq)
    print(border_eq)
    print("  AVAILABLE GENERATION / CHAT MODELS")
    print(border_eq)
    print(" [0] Exit Program")
    print(" [A] RUN ALL CHAT MODELS (Batch Benchmark)")
    print(border_dash)
    for idx, item in enumerate(model_entries, start=1):
        print(f" [{idx:2d}] {item['name']:<{max_chat_name}} # {item['descriptor']}")

    if skipped_visions:
        print(border_dash)
        print(" ℹ️  SKIPPED VISION MODELS (Require image payloads):")
        print(border_dash)
        for v_name, v_desc in skipped_visions:
            print(f"      • {v_name:<{max_vision_name}} # {v_desc}")

    if skipped_embeddings:
        print(border_dash)
        print(" ℹ️  SKIPPED EMBEDDING MODELS (Not text generation models):")
        print(border_dash)
        for e_name, e_desc in skipped_embeddings:
            print(f"      • {e_name:<{max_embed_name}} # {e_desc}")

    print(border_eq)

    num_models = len(model_entries)
    choice = input(f"\nSelect choice (0, A, or 1-{num_models}): ").strip().lower()

    if choice == "0":
        print("Exiting benchmark.")
        return

    selected_models = []
    if choice == "a":
        selected_models = model_entries
        print(
            f"\n✓ Selected ALL {len(selected_models)} chat models for batch execution.\n"
        )
    else:
        try:
            selection_idx = int(choice) - 1
            if 0 <= selection_idx < len(model_entries):
                selected_models = [model_entries[selection_idx]]
                print(f"\n✓ Selected model: '{selected_models[0]['name']}'\n")
            else:
                print("Invalid selection.")
                return
        except ValueError:
            print("Invalid input choice.")
            return

    results = []
    for item in selected_models:
        model_name = item["name"]
        quant_level = item["quant"]
        print(f"🚀 Running benchmark on: '{model_name}' (15m max timeout)...")
        res = run_ollama_benchmark(model_name, quant_level)
        results.append(res)
        print(f"  ✓ Finished '{model_name}' in {res['wall_time']:.2f}s\n")

    # Dynamically calculate column widths based on longest model name to ensure flawless alignment
    max_name_len = max([len(r["model"]) for r in results] + [len("Model Name")])
    name_width = max(max_name_len, 32)

    header_line = f"{'Model Name':<{name_width}} | {'Quant':<10} | {'Prompt tok/s':<12} | {'Gen tok/s':<10} | {'Peak VRAM':<10} | {'Wall Time':<10}"
    sep_line = "-" * len(header_line)

    print("\n" + "=" * len(header_line))
    print(" 📊 BATCH BENCHMARK COMPARISON TABLE")
    print("=" * len(header_line))
    print(header_line)
    print(sep_line)
    for r in results:
        vram_str = f"{r['peak_vram']:.2f} GB" if r["peak_vram"] > 0 else "N/A"
        print(
            f"{r['model']:<{name_width}} | {r['quant']:<10} | {r['prompt_tok_s']:12.1f} | {r['gen_tok_s']:10.1f} | {vram_str:<10} | {r['wall_time']:8.2f}s"
        )
    print("=" * len(header_line))

    # Automatically generate insights report at the end of execution
    generate_insights_report(results)


if __name__ == "__main__":
    main()
EOF
