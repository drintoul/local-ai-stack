#!/usr/bin/env python3
"""
langchain_demo.py — Generates a handful of Langfuse traces so the UI has
data to display. Uses the local Ollama model via LangChain, wrapped with
Langfuse's CallbackHandler. Sessions/users metadata groups runs in the
Langfuse UI (Sessions / Users views).

Usage:
  ./langchain_demo.py
"""

import json
import os
import sys
import urllib.request

# --- Env setup: keys + hosts, sourced from ../.env where convenient ---------
ENV_FILE = os.path.join(os.path.dirname(__file__), "..", ".env")
def env_var(name: str, default: str = "") -> str:
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in open(ENV_FILE):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default

os.environ.setdefault("LANGFUSE_PUBLIC_KEY", env_var("LANGFUSE_INIT_PUBLIC_KEY"))
os.environ.setdefault("LANGFUSE_SECRET_KEY", env_var("LANGFUSE_INIT_SECRET_KEY"))
os.environ.setdefault("LANGFUSE_HOST", "http://localhost:3000")
OLLAMA_HOST = env_var("OLLAMA_HOST", "http://localhost:11434")
MODEL = env_var("DEMO_MODEL", "llama3.1:8b")

from langfuse.langchain import CallbackHandler
from langfuse import get_client
from langchain_ollama import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

llm = ChatOllama(base_url=OLLAMA_HOST, model=MODEL, temperature=0.7)

def run(prompt_tmpl: str, invoke_input: dict, session: str, user: str,
        name: str) -> None:
    """Run a chain traced into a named session."""
    handler = CallbackHandler()
    chain = ChatPromptTemplate.from_template(prompt_tmpl) | llm | StrOutputParser()
    out = chain.invoke(invoke_input, config={
        "callbacks": [handler],
        "metadata": {
            "langfuse_session_id": session,
            "langfuse_user_id": user,
            "langfuse_tags": ["demo", name],
        },
    })
    print(f"  [{name}] -> {out[:80]}...")


def main() -> None:
    print(f"Ollama : {OLLAMA_HOST}  model={MODEL}")
    print(f"Langfuse: {os.environ['LANGFUSE_HOST']}  keys={os.environ['LANGFUSE_PUBLIC_KEY'][:12]}...")
    print()

    # Session 1: simple QA chain -------------------------------------------
    run("Answer briefly: {question}", {"question": "What is Langfuse?"},
        session="demo-qa", user="demo-user", name="qa-chain")

    run("Follow-up on your last answer: {question}",
        {"question": "How does it differ from LangSmith?"},
        session="demo-qa", user="demo-user", name="qa-chain")

    # Session 2: multi-step "agent-ish" pipeline -----------------------------
    topic = "the solar system"
    plan = ChatPromptTemplate.from_template(
        "List 3 subtopics to research for: {topic}").invoke({"topic": topic})
    run("Expand briefly on each: {subtopics}",
        {"subtopics": plan.to_messages()[-1].content if hasattr(plan, 'to_messages') else str(plan)},
        session="demo-pipeline", user="demo-user", name="expand-step")
    run("Write a one-line TL;DR for these notes: {notes}",
        {"notes": "planets, moons, asteroids"},
        session="demo-pipeline", user="demo-user", name="summarize-step")

    # Session 3: extraction-style call with JSON-ish output ------------------
    run("Extract the key entities from this sentence as a list: {text}",
        {"text": "The Firecrawl API scraped quotes.toscrape.com using Playwright on port 3002."},
        session="demo-extraction", user="demo-user", name="extract-chain")

    get_client().flush()
    print()
    print("Done — traces flushed. Open the UI:")
    print(f"  {os.environ['LANGFUSE_HOST']} -> Tracing -> Traces")
    print("  Sessions: demo-qa (2 runs), demo-pipeline (2 runs), demo-extraction (1)")


if __name__ == "__main__":
    main()
