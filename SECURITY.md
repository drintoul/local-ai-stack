# Security Policy

## Supported Versions

This project tracks upstream container images. Only the latest commit on
`main` is supported — keep your deployment updated with:

```bash
docker compose pull && docker compose up -d
```

## Reporting a Vulnerability

Please **do not** open a public issue for security reports.
Email **drintoul@gmail.com** with a description, affected component,
and reproduction steps. Expect an acknowledgement within a few days.

## Secrets & Configuration

- `.env` contains generated secrets and is **gitignored** — never commit it.
- Rotate any secret accidentally committed using `openssl rand -hex 32`.
- SearXNG's `searxng/settings.yml` ships with a placeholder `secret_key` —
  regenerate it before exposing the service outside localhost.

## Exposure Notes

These services are designed for localhost/trusted-LAN use:

- Ollama (`11434`), Firecrawl (`3002`), and Langfuse (`3000`) have **no
  authentication** by default — do not expose them to untrusted networks
  without a reverse proxy and auth.
- Firecrawl's queue admin UI (`/admin/<FIRECRAWL_BULL_AUTH_KEY>/queues`) is
  protected only by the key in `.env`.
- Langfuse INIT credentials in `.env` are for local development; change the
  admin password and rotate API keys before any shared deployment.
