# AGENTS.md — ai-stack repo briefing

## What this is

**Private AI Stack**: a self-hosted, docker-compose AI stack for small businesses —
chat UI, LLM gateway, guardrails, RAG over company documents, and workflow automation.

**Hard constraint: customer data never leaves the building.**

- LLM inference, embeddings, reranking, and the vector DB all run locally on one GPU host.
- No cloud model APIs, no external runtime calls, no telemetry (explicitly disabled in
  Open WebUI and n8n).
- The only network egress is at *deploy time*: image pulls, apt/pip, and model downloads
  (Qwen3 GGUF + HuggingFace embedding models).
- Flag anything that risks this constraint before adding it.

Repo: `github.com/privateInferenceAI/ai-stack`, branch `main`.

## Architecture

Single Docker host, **10 containers** on an external bridge network `ai-net`;
all host state lives under `/opt/ai-stack/`.

Chat request path:

```
Browser → Open WebUI :3000 → guardrails function (inlet: denial + RAG injection,
outlet: PII redaction) → LiteLLM :4000 → llama.cpp :8080 (Qwen3-14B)
```

RAG path (inside the guardrails function):

```
query → TEI embeddings → Qdrant company_docs (role-filtered ACL) → TEI reranker
→ top-10 chunks prepended to the user message
```

| Service | Image / build | Host port | GPU | Purpose |
|---|---|---|---|---|
| llamacpp | `ghcr.io/ggml-org/llama.cpp` (digest-pinned) | 8080 | ✓ | llama.cpp server, `Qwen3-14B-Q4_K_M.gguf`, ctx 32768 |
| litellm | `ghcr.io/berriai/litellm` (digest-pinned) | 4000 | | Gateway; single model `company-ai` → `openai/qwen3-14b` @ `http://llamacpp:8080/v1` |
| postgres | `postgres:16-alpine` | — | | LiteLLM DB (keys, spend); deliberately unpublished |
| open-webui | `ghcr.io/open-webui/open-webui` (digest-pinned) | 3000 | | Chat UI; model-filtered to `company-ai`; signups default `pending`; telemetry off |
| qdrant | `qdrant/qdrant:v1.11.3` | — | | Vector DB; collection `company_docs` (1024-dim, cosine) |
| embeddings | `ghcr.io/huggingface/text-embeddings-inference:1.6` | — | ✓ | `BAAI/bge-m3` |
| reranker | same TEI 1.6 image | — | ✓ | `BAAI/bge-reranker-v2-m3` |
| ingestion | local build (`ingestion/`) | — | | Periodic worker (default every 900s) with manifest no-op + deletion reconciliation; manual run via `docker exec` |
| n8n | `docker.n8n.io/n8nio/n8n` (digest-pinned) | 5678 | | Workflow automation; diagnostics off |
| mailpit | `axllent/mailpit` (digest-pinned) | 8025 | | Test SMTP capture for demo workflows |

Healthchecks exist only on postgres (`pg_isready`) and litellm (`/health/liveliness`).

### Guardrails

- `guardrails/guardrails-function.py` is an **Open WebUI Filter function**
  (inlet/outlet pipes) — *not* a LiteLLM callback, and not mounted by compose. It is
  installed manually in the WebUI (Admin → Functions), enabled globally, with valve
  `QDRANT_API_KEY` set.
- `inlet`: substring-match input denial (SSNs, prompt injection, salary probes), then
  RAG with role ACL — `admin` role sees `company` + `executive` chunks; everyone else
  sees `company` only. RAG errors fail open.
- `outlet`: regex PII redaction (SSN pattern → `[REDACTED]`).
- `guardrails/policy.txt` is the human-readable policy mirror. **Policy and code must
  stay in sync** — see `docs/guardrails-customization.md`.

### Ingestion

- `documents/company/` + `documents/executive/` → text extraction (.pdf/.docx/.txt/.md)
  → 512-char chunks (64 overlap) → bge-m3 embeddings → Qdrant `company_docs`.
  Payload `acl` = source folder; deterministic uuid5 point IDs make re-runs idempotent.
- Runs automatically every `INGEST_INTERVAL_SECONDS` (default 900s, `.env`-tunable)
  in the ingestion container; a sha256 manifest makes unchanged cycles free, and
  chunks of deleted/changed files are removed. Immediate run:
  `docker exec ingestion python3 /app/ingest.py`.

## Repository layout

```
docker-compose.yml              all 10 services (requires external network `ai-net`)
litellm/config.yaml             single local model; master key + DB URL from env
guardrails/policy.txt           human-readable policy
guardrails/guardrails-function.py  Open WebUI filter (installed via WebUI, not compose)
ingestion/Dockerfile, ingest.py document → Qdrant pipeline
documents/company/              sample all-users doc (expense policy)
documents/executive/            sample admin-only doc (exec comp)
exports/MyWorkflow.json         n8n demo: invoice approval w/ human gate (inactive by default)
genenv.sh                       generates /opt/ai-stack/.env (openssl secrets, mode 600)
gittar.sh                       creates runtime dirs Git can't track (misnomer: makes no tar)
phase1a.sh                      OS prep + NVIDIA driver (pre-reboot)
phase1b.sh                      Docker + NVIDIA toolkit + UFW/fail2ban + ai-net + model download
pathb.sh                        fresh-install orchestrator: env → build → up → mint keys → seed
backup.sh / restore.sh          on-demand backup / full restore
docs/                           manual-build.md, scripted-build.md, backup-restore.md
```

## Build & run

**Target host:** Ubuntu 24.04 + NVIDIA GPU. Dev/test box is an AWS g5.2xlarge
(A10G 24 GB VRAM, 8 vCPU, 32 GB RAM) — size models to that ceiling. ~200 GB disk.

Scripted path (canonical; full detail in `docs/scripted-build.md`):

1. Copy repo contents to the **top level** of `/opt/ai-stack` (required layout).
2. `sudo ./phase1a.sh` → reboot → `sudo ./phase1b.sh`
   (installs Docker, NVIDIA container toolkit, UFW/fail2ban, creates `ai-net`,
   downloads the ≈9 GB Qwen3-14B GGUF).
3. `sudo bash ./pathb.sh` → gittar → genenv → build ingestion image →
   `docker compose up -d` → waits for llamacpp model-ready → mints LiteLLM virtual
   keys for WebUI/n8n → seeds Qdrant. Success = `containers: 10/10`.
4. Browser wiring (SSH-tunnel ports 3000/5678/8025): create WebUI admin account →
   disable signups (Settings → Authentication) → import + globally enable the
   guardrails function (set valve `QDRANT_API_KEY`) → n8n owner account → n8n OpenAI
   credential (`http://litellm:4000/v1`, key `N8N_VIRTUAL_KEY`) + SMTP credential
   (`mailpit:1025`, test/test, TLS off) → import `exports/MyWorkflow.json`.

Manual path: `docs/manual-build.md` (the same build longhand).

**Backup:** `cd /opt/ai-stack && ./backup.sh [dest]` → `backups/ai-stack-backup-<ts>/`
capturing config (incl. `.env`), live `pg_dump`, and tarballs of qdrant/webui/n8n data,
documents, exports — **not** the 9 GB model. **Restore:** `sudo ./restore.sh <backup-dir>`
(requires typed `yes`). See `docs/backup-restore.md`.

## Conventions

- **Branches:** work on feature branches; do not commit directly to `main` unless asked.
- **Secrets:** never commit secrets. `.env` is generated on-box by `genenv.sh`
  (`openssl rand -hex 24`, mode 600) and gitignored, along with all runtime data dirs.
- **Images:** prefer digest pinning (`image@sha256:…`); version tags with a freeze-digest
  comment are the current fallback for the rest.
- **Host layout:** everything lives at `/opt/ai-stack/` and compose runs from there —
  compose-level `${VAR}` substitution depends on `.env` sitting in that directory.
- **Non-GPU validation:** on machines without a GPU, limit checks to reading code,
  `shellcheck`, `docker compose config`, and linting. Never `docker compose up`.
- **Doc/script embedding:** `docs/manual-build.md` and `docs/scripted-build.md` embed
  copies of the scripts and compose file. Embedded copies must be **byte-exact** —
  after editing either side, run `python3 scripts/check-doc-sync.py` (exits 1 on
  drift; `--write` regenerates embedded copies from the real files).

## Known issues / gotchas

1. **llamacpp :8080 is published on the host** as a build-time debug port — bypasses
   LiteLLM and the guardrails. Documented in compose + both guides; removal or
   localhost-bind at production lock-down is tracked in GitHub issue #2.
2. **No automated guardrails install** — the filter is installed/tuned manually via
   WebUI → Functions (see `docs/guardrails-customization.md`). An API-script
   approach is parked in issue #14 (kept manual on purpose until the manual
   process is well understood).
3. **Healthchecks exist only on postgres and litellm.** pathb.sh gates installs on
   llamacpp model-ready + TEI Ready, but a compose-level llamacpp healthcheck
   (→ `depends_on: service_healthy`) is pending the curl/wget image check in issue #5.

Recently resolved (kept for context): policy/code `legal_advice` mismatch (policy
v1.1 + `docs/guardrails-customization.md`), restore.sh postgres password sync,
README `exports/` layout, doc/script drift (byte-exact + guarded by
`scripts/check-doc-sync.py`), TEI first-boot egress (pre-download +
`HF_HUB_OFFLINE=1`), the llamacpp startup race (pathb model-ready wait), the
dangling `Bug N` comments, and ingestion scheduling (periodic worker + manifest
+ deletion reconciliation).

## Canary answers (smoke-testing RAG + ACL)

- Expense-policy mileage rate: **67 cents/mile** (`company` ACL — any user should get this).
- CEO base salary: **$425,000** (`executive` ACL — admin only; non-admins must *not* see it).

Roadmap notes (from README/docs): Whisper voice via speaches (would be container #11),
richer file-type + OCR ingestion (dedicated pipeline), 48 GB GPU tier.
