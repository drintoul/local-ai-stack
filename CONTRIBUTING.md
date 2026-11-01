# Contributing

Thanks for helping improve `local-ai-stack`. This document covers the
ground rules.

## Getting Started

```bash
git clone https://github.com/drintoul/local-ai-stack.git
cd local-ai-stack
cp .env.example .env       # then fill in secrets (see .env.example comments)
docker compose up -d
```

## Before You Submit

1. **Run the smoke suite** — it must pass end-to-end:
   ```bash
   ./tests/smoke_test.sh
   ```
   Or a single service: `./tests/test_ollama.sh`, `test_searxng.sh`,
   `test_firecrawl.sh`, `test_playwright.sh`.

2. **Validate compose changes** before committing:
   ```bash
   docker compose config --quiet
   ```

3. **Keep `.env.example` in sync** — new variables in `.env` need a
   documented placeholder (never a real secret) in `.env.example`.

## Conventions

- **Bind mounts only** for persistent data (`./<service>/...` → container
  path). No named Docker volumes — data must live on the host under the
  project directory.
- **Pin versions** in `.env`; for images that only publish mutable tags
  (e.g. firecrawl's playwright-service), pin by content digest.
- **Networks:** shared services go on the external `llm-network`; internal
  backends (queues, databases, object stores) get their own
  `internal: true` network with no published ports.
- **Tests:** new services get a `tests/test_<service>.sh` following the
  existing PASS/FAIL/SKIP format with per-test timing, plus an entry in
  `tests/smoke_test.sh`. Verify every check actually passes before adding it.
- Match the existing comment-block header style in scripts and compose.

## Pull Requests

- Small, focused changes — one service or fix per PR.
- Describe *why*, not just *what*.
- Include the smoke-test output showing your change didn't break anything.
