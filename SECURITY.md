# Security Policy

## Supported Versions

This project tracks upstream container images (pinned by tag or digest in
`.env`). Only the latest commit on `main` is supported — keep your deployment
updated with:

```bash
docker compose pull && docker compose up -d --build
```

## Reporting a Vulnerability

Please **do not** open a public issue for security reports.
Email **drintoul@gmail.com** with a description, affected component,
and reproduction steps. Expect an acknowledgement within a few days.

## Secrets & Configuration

- `.env` contains generated secrets and is **gitignored** (mode `640`) —
  never commit it. `.env.example` uses `[SECRET]` placeholders only.
- Rotate any secret accidentally committed using `openssl rand -hex 32`
  (`LANGFUSE_ENCRYPTION_KEY` needs 64 hex chars).
- SearXNG's `searxng/settings.yml` ships with a placeholder `secret_key` —
  regenerate it before exposing the service outside localhost.

## Threat Model

Intended deployment: single Linux host, containers trusted, consumers are
local tools and other Docker stacks on `app-network`. **Nothing here is
designed to face the internet.**

### Published ports (all interfaces)

| Port | Service | Auth |
|---|---|---|
| `11434` | Ollama | none |
| `8088` | SearXNG | none |
| `3000` | Langfuse UI | own login (`LANGFUSE_INIT_*`) |
| `9090` | MinIO console | `MINIO_ROOT_*` |
| `18080` | Gateway | bearer or `ALLOW_UNAUTHENTICATED` |
| `18081` | MCP | same key as gateway |
| `3002` | Firecrawl | **127.0.0.1 only** — gateway is the front door |

Consequences: anything on your LAN can run inference on Ollama, search via
SearXNG, and — while `ALLOW_UNAUTHENTICATED=true` — drive Firecrawl,
Interact (a full browser), and MCP tools through the gateway. That's fine on
a trusted LAN; on anything untrusted, blank `ALLOW_UNAUTHENTICATED` so every
Firecrawl/interact path requires `Authorization: Bearer $GATEWAY_API_KEY`.
`/ollama/*` and `/searxng/*` are always open by design (same exposure as
ports 11434/8088 already have).

### Notable trust decisions

- **Docker socket in gateway** — mounted **read-only** to power
  `GET /containers`. The endpoint is behind the gateway's auth (when
  enabled) and can only *read* container metadata; it cannot create or
  control containers.
- **SSRF guards** — both playwright-service and interact refuse
  private/internal targets by default (`INTERACT_ALLOW_PRIVATE=1` opts out;
  `ALLOW_LOCAL_WEBHOOKS` similarly gates Firecrawl webhooks).
- **Container data dirs** — `firecrawl/postgres`, `langfuse/*`, `searxng/`
  are owned by container-internal UIDs. Do not `chown -R` the repo; Postgres
  refuses to start on a data directory it doesn't own.
- **Langfuse INIT credentials** are for local development; change the admin
  password and rotate API keys before any shared deployment.
