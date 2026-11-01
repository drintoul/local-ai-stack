# Langfuse — Configure & Use

Self-hosted [Langfuse](https://langfuse.com) v4 for LLM observability: trace trees,
token/latency/cost analytics, prompt management, scores/evals, and datasets.
Open-source equivalent of LangSmith.

> Official docs: <https://langfuse.com/docs> · Self-hosting: <https://langfuse.com/self-hosting>

---

## 1. Access

| | |
| :--- | :--- |
| **Web UI** | `http://localhost:3000` |
| **Login** | `admin@local.ai` / `LANGFUSE_INIT_USER_PASSWORD` (in `.env`) |
| **Org / Project** | `Local AI Stack` / `local` (pre-provisioned on first boot) |
| **API keys** | `LANGFUSE_INIT_PUBLIC_KEY` / `LANGFUSE_INIT_SECRET_KEY` in `.env` |

Create additional users/keys in the UI: **Project Settings → API Keys**
and **Organization Settings → Members**.

## 2. Architecture

Six containers (see `docker-compose.yaml`):

- `langfuse-web` — UI + API, port `3000` (host). Health: `/api/public/health`
- `langfuse-worker` — background processing (ClickHouse event propagation)
- `langfuse-postgres` — users, projects, prompts, datasets (OLTP)
- `langfuse-clickhouse` — trace/observation analytics store (`events_full` table)
- `langfuse-minio` — S3 blob storage for raw events & media (port `9090`, console `127.0.0.1:9091`)
- `langfuse-redis` — ingestion queue

Backends live on the private `langfuse-internal` network (no host ports);
web + worker are also on `llm-network` so LLM-assisted evals can reach
`ollama:11434`. All data is on bind mounts under `./langfuse/`.

## 3. Sending Traces (Langfuse v4 = OpenTelemetry)

v4 ingests spans via **OTLP** — legacy `/api/public/ingestion` is disabled
(`events_only` mode). API auth is HTTP Basic with `public-key:secret-key`.

### Python SDK (recommended)

```bash
pip install langfuse
```

```python
import os
os.environ["LANGFUSE_PUBLIC_KEY"] = "pk-lf-localdev"
os.environ["LANGFUSE_SECRET_KEY"] = "sk-lf-..."     # from .env
os.environ["LANGFUSE_HOST"] = "http://localhost:3000"  # or http://langfuse-web:3000 from llm-network

from langfuse import observe, get_client

@observe()
def run(query: str):
    # any LLM call here is traced automatically
    ...

run("hello")
get_client().flush()   # flush spans before exit
```

The SDK auto-sends to `POST /api/public/otel/v1/traces`. If your app runs in a
container on `llm-network`, use `LANGFUSE_HOST=http://langfuse-web:3000`.

### Raw OTLP (curl)

```bash
source .env   # provides LANGFUSE_INIT_* keys
curl -X POST http://localhost:3000/api/public/otel/v1/traces \
  -u "$LANGFUSE_INIT_PUBLIC_KEY:$LANGFUSE_INIT_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{},"scopeSpans":[{"scope":{"name":"demo"},
        "spans":[{"traceId":"<32-hex>","spanId":"<16-hex>","name":"demo-span",
        "startTimeUnixNano":"<ns>","endTimeUnixNano":"<ns>","status":{"code":1}}]}]}]}'
```

### Scores

Scores still use the REST API (works in `events_only` mode):

```bash
curl -X POST http://localhost:3000/api/public/scores \
  -u "$LANGFUSE_INIT_PUBLIC_KEY:$LANGFUSE_INIT_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"traceId":"<trace-id>","name":"quality","value":0.9}'
```

### LangChain / integrations

The official integrations list (LangChain `CallbackHandler`, LlamaIndex,
OpenAI wrapper, Vercel AI SDK, OTEL Collector) is at
<https://langfuse.com/integrations> — point them at the same host + keys.

---

## 4. Worked Examples (on this stack)

All examples assume:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-localdev
export LANGFUSE_SECRET_KEY=<LANGFUSE_INIT_SECRET_KEY from .env>
export LANGFUSE_HOST=http://localhost:3000   # or http://langfuse-web:3000 from llm-network
```

### Example A — Trace a plain Ollama call (`@observe`)

```python
import urllib.request, json
from langfuse import observe, get_client

@observe(name="ollama-chat")
def chat(prompt: str) -> str:
    req = urllib.request.Request(
        "http://localhost:11434/api/chat",
        data=json.dumps({
            "model": "llama3.1:8b",
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }).encode(),
        headers={"Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req).read())
    get_client().update_current_generation(
        input=prompt,
        output=out["message"]["content"],
        model="llama3.1:8b",
    )
    return out["message"]["content"]

print(chat("Why is the sky blue?"))
get_client().flush()
```

Open **Tracing → Traces** in the UI: you'll see `ollama-chat` with the
prompt as input and the completion as output, plus wall-clock latency.

### Example B — LangChain chain (`CallbackHandler`)

```bash
pip install langfuse langchain langchain-ollama
```

```python
from langfuse.langchain import CallbackHandler
from langchain_ollama import ChatOllama
from langchain_core.prompts import ChatPromptTemplate

handler = CallbackHandler()          # picks up LANGFUSE_* env vars
chain = ChatPromptTemplate.from_template("Summarize: {text}") | ChatOllama(
    base_url="http://localhost:11434", model="llama3.1:8b")

result = chain.invoke({"text": "Langfuse is an LLM observability platform."},
                      config={"callbacks": [handler]})
```

The handler creates a trace with one span per chain step — prompt template
and model call each get input/output, latency, and token counts. Attach
metadata via `config={"callbacks":[handler], "metadata":{
"langfuse_session_id":"demo-session","langfuse_user_id":"dave"}}` — sessions
and users then group under **Sessions** / **Users** in the UI.

### Example C — LangGraph agent

Same handler, passed into the graph's config:

```python
from langgraph.graph import StateGraph, MessagesState, START, END
from langchain_ollama import ChatOllama
from langfuse.langchain import CallbackHandler

llm = ChatOllama(base_url="http://localhost:11434", model="llama3.1:8b")
def call_model(state): return {"messages": [llm.invoke(state["messages"])]}

g = StateGraph(MessagesState)
g.add_node("agent", call_model); g.add_edge(START, "agent"); g.add_edge("agent", END)
graph = g.compile()

graph.invoke({"messages": [("user", "What is 2+2?")]},
             config={"callbacks": [CallbackHandler()],
                     "metadata": {"langfuse_session_id": "graph-demo"}})
```

Each graph node becomes a span under the run trace — you get the full
agent step-by-step execution, not just the final answer.

### Example D — Scoring a trace (evaluation)

```python
client = get_client()
client.create_score(trace_id="<trace-id>", name="accuracy",
                    value=0.95, comment="factually correct")
client.flush()
```

Scores show on the trace and roll up under **Scores** and dashboard widgets.

### Monitoring in the UI

| View | What it shows |
| :--- | :--- |
| **Tracing → Traces** | Every trace: spans, latency per step, input/output, cost |
| **Sessions / Users** | Multi-turn grouping via `langfuse_session_id` / `langfuse_user_id` metadata |
| **Dashboards** | Latency %iles, token throughput, cost over time |
| **Prompts** | Version-controlled prompt templates — fetched at runtime via `client.get_prompt()` |
| **Scores / Evals** | Quality ratings on traces; LLM-judged evals can use `ollama:11434` |
| **Datasets** | Test sets for regression runs against new prompts/models |

## 5. Configuration

Everything lives in `.env` (secrets are generated, gitignored):

| Variable | Purpose |
| :--- | :--- |
| `LANGFUSE_VERSION` | Image tag (`4`) pulled from `docker.langfuse.com` |
| `LANGFUSE_PORT` | Web UI port (default `3000`) |
| `MINIO_BIND_PORT` | MinIO port for browser media uploads (`9090`) |
| `LANGFUSE_NEXTAUTH_SECRET` / `SALT` / `ENCRYPTION_KEY` | Session & credential crypto — **do not lose**, rotating invalidates sessions |
| `LANGFUSE_{POSTGRES,CLICKHOUSE,REDIS}_PASSWORD/AUTH` | Backend credentials |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | S3 credentials |
| `LANGFUSE_INIT_*` | First-boot provisioning (org, project, user, API keys). Requires `ORG_ID` + `PROJECT_ID` — name vars alone are ignored |

Shared env for web + worker is anchored once as `x-langfuse-env` in
`docker-compose.yaml`.

## 6. Notes & Gotchas (learned on this stack)

- **`HOSTNAME=0.0.0.0` is required** on web/worker — with two networks
  attached, Next.js otherwise binds a single interface and host port
  forwarding fails.
- **v4 = OTEL only.** Tutorials using `/api/public/ingestion` won't work
  unless you set `LANGFUSE_MIGRATION_V4_WRITE_MODE=dual` on web + worker
  (migration bridge, off by default here).
- **Verify ingestion** by querying ClickHouse directly (no legacy REST
  `/traces` API in `events_only` mode):
  ```bash
  docker exec langfuse-clickhouse clickhouse-client \
    --query "SELECT name FROM events_full ORDER BY timestamp DESC LIMIT 5"
  ```
- **`tests/test_langfuse.sh`** covers all of this end-to-end (health,
  UI, OTEL ingest → `events_full`, auth rejection).

## 7. Backups

State lives under `./langfuse/` (postgres, clickhouse, minio, redis).
For a logical trace backup prefer ClickHouse exports or the UI's
dataset export; for disaster recovery, stop the stack and copy the
`langfuse/` directory (files are container-uid owned — use sudo).
