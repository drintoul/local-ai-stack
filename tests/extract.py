#!/usr/bin/env python3
"""
extract.py — Local structured extraction pipeline.

Replicates Firecrawl's /extract behavior without needing OpenAI:
  1. Scrape a URL to markdown via the local Firecrawl API.
  2. Extract structured JSON from that markdown via local Ollama
     (format:"json" forces parseable output).

Usage:
  ./extract.py URL "prompt describing what to extract"
  ./extract.py URL --schema schema.json
  ./extract.py URL --prompt "get prices" --model qwen3:8b

Env vars:
  FIRECRAWL_HOST  (default http://localhost:3002)
  OLLAMA_HOST     (default http://localhost:11434)
  EXTRACT_MODEL   (default llama3.1:8b)
"""

import argparse
import json
import os
import sys
import urllib.request

FIRECRAWL_HOST = os.environ.get("FIRECRAWL_HOST", "http://localhost:3002").rstrip("/")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
DEFAULT_MODEL = os.environ.get("EXTRACT_MODEL", "llama3.1:8b")


def post_json(url: str, payload: dict, timeout: int) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def scrape_markdown(url: str, timeout: int) -> str:
    data = post_json(
        f"{FIRECRAWL_HOST}/v1/scrape",
        {"url": url, "formats": ["markdown"]},
        timeout,
    )
    if not data.get("success"):
        sys.exit(f"scrape failed: {data.get('error', 'unknown error')}")
    md = data.get("data", {}).get("markdown", "")
    if not md:
        sys.exit("scrape returned empty markdown")
    return md


def extract(markdown: str, prompt: str, model: str, timeout: int) -> dict:
    full_prompt = (
        "Extract the requested information from the page content below. "
        "Reply with ONLY a JSON object, no commentary.\n\n"
        f"REQUEST: {prompt}\n\n"
        "PAGE CONTENT:\n"
        f"{markdown[:24000]}"
    )
    data = post_json(
        f"{OLLAMA_HOST}/api/generate",
        {"model": model, "prompt": full_prompt, "format": "json", "stream": False},
        timeout,
    )
    resp = data.get("response", "").strip()
    if "error" in data:
        sys.exit(f"ollama error: {data['error']}")
    try:
        return json.loads(resp)
    except json.JSONDecodeError:
        sys.exit(f"model returned non-JSON output:\n{resp[:500]}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Scrape a URL and extract structured JSON via local Ollama.")
    ap.add_argument("url", help="URL to scrape")
    ap.add_argument("prompt", nargs="?", help="What to extract (natural language)")
    ap.add_argument("--schema", help="Path to a JSON file: {\"prompt\": ..., \"schema\": {...}}")
    ap.add_argument("--model", default=DEFAULT_MODEL, help=f"Ollama model (default {DEFAULT_MODEL})")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    prompt = args.prompt
    schema_hint = ""
    if args.schema:
        spec = json.load(open(args.schema))
        prompt = prompt or spec.get("prompt", "")
        if spec.get("schema"):
            schema_hint = f"\nMatch this JSON schema exactly: {json.dumps(spec['schema'])}"
    if not prompt:
        ap.error("provide a prompt (arg or --schema file)")

    markdown = scrape_markdown(args.url, args.timeout)
    result = extract(markdown, prompt + schema_hint, args.model, args.timeout)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
