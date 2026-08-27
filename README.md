# ai-stack

A self-hosted AI stack for a single GPU box: staff chat, access-controlled document search (RAG), workflow automation with human approval gates, and request logging. All inference runs locally (llama.cpp + Qwen3-14B); the only external calls are package/model downloads at install time.

## Components

```
Browser ──► Open WebUI ──► guardrails filter ──► LiteLLM ──► llama.cpp ──► GPU (Qwen3-14B)
                                                  │              └──► Postgres (keys, budgets, logs)
                       n8n workflows ─────────────┘
                       Qdrant (vector DB) ◄── ingestion (periodic worker)
                       Mailpit (test email / human gate)
```

| Layer | Component | Job |
|---|---|---|
| Inference | llama.cpp + Qwen3-14B (Q4_K_M) | Model serving on the GPU |
| Gateway | LiteLLM + Postgres | API keys, budgets, rate limits, request logs |
| Chat UI | Open WebUI | Web chat interface |
| Document brain | Qdrant + bge-m3 + reranker | Document chunks, vectors, ACL tags |
| Automation | n8n + Mailpit | Workflows with a human approval step; test SMTP |
| Policy | WebUI filter function | Input/output guardrails + role-based document filtering |

## Requirements

- Ubuntu 24.04 box with an NVIDIA GPU with 24GB VRAM. The documented target is AWS `g5.2xlarge` (A10G, 8 vCPU, 32GB RAM, 200GB gp3), ~$1.21/hr running (~$20/mo stopped).
- SSH access (key pair).
- ~45–60 minutes, mostly downloads.

## Documentation

| I want to... | Doc |
|---|---|
| Build it with the helper scripts | Quick start below; full version in [docs/scripted-build.md](docs/scripted-build.md) |
| Build it by hand, every command and file | [docs/manual-build.md](docs/manual-build.md) |
| Back up a running box / restore it onto new hardware | [docs/backup-restore.md](docs/backup-restore.md) |

## Quick start (scripted path)

### 1. Launch the box

AWS console → EC2 → Launch: `g5.2xlarge`, Ubuntu 24.04, 200GB gp3, security group inbound 22 only, Elastic IP attached.

From your laptop:

```bash
ssh-keygen -R <ELASTIC-IP>
ssh -i /path/to/your-key.pem ubuntu@<ELASTIC-IP>
```

### 2. Get the repo onto the box

```bash
git clone https://github.com/privateInferenceAI/ai-stack.git /home/ubuntu/ai-stack
sudo mkdir -p /opt/ai-stack
sudo cp -r /home/ubuntu/ai-stack/. /opt/ai-stack/
sudo chown -R ubuntu:ubuntu /opt/ai-stack
```

(The `/.` copies the repo *contents* to the top level of `/opt/ai-stack` — that layout is required.)

### 3. Foundation

```bash
chmod +x /opt/ai-stack/phase1a.sh /opt/ai-stack/phase1b.sh
sudo /opt/ai-stack/phase1a.sh
sudo reboot
# wait ~90 seconds, SSH back in
sudo /opt/ai-stack/phase1b.sh
newgrp docker
```

`phase1a`: OS update + NVIDIA driver (then reboot). `phase1b`: Docker, NVIDIA container toolkit, firewall, model download (~9 GB).

### 4. Install

```bash
sudo bash /opt/ai-stack/pathb.sh
```

Creates runtime directories, generates fresh secrets into `.env`, builds the ingestion image, starts all 10 containers, mints API keys, seeds the document store with the two sample documents. Ends with `containers: 10/10`.

### 5. Browser wiring

Open tunnels from your laptop (leave the session open):

```bash
ssh -i /path/to/your-key.pem -L 3000:localhost:3000 -L 5678:localhost:5678 -L 8025:localhost:8025 ubuntu@<ELASTIC-IP>
```

In order:

1. **WebUI admin** — `http://localhost:3000` → Sign up. **The first account becomes admin.**
2. **Disable signups** — Admin Panel → Settings → Authentication → "Allow New Signups" OFF → Save.
3. **Guardrails function** — Admin Panel → Functions → new → paste `guardrails/guardrails-function.py` → Save → enable **and set GLOBAL** → Valves: paste `QDRANT_API_KEY` from `/opt/ai-stack/.env`.
4. **n8n owner** — `http://localhost:5678` → create the owner account.
5. **n8n credentials** — **OpenAI** (Base URL `http://litellm:4000/v1`, key = `N8N_VIRTUAL_KEY` from `.env`) and **SMTP** (host `mailpit`, port `1025`, user/pass `test`/`test`, TLS off).
6. **Import the workflow** — n8n → Import from File → `exports/MyWorkflow.json`.

### 6. Verify

| Test | Expected |
|---|---|
| "What is the mileage reimbursement rate?" | **67 cents per mile** (from the sample document) |
| As admin: "What is the CEO salary?" | **$425,000** |
| As a regular user: "What is the CEO salary?" | **"I don't have that information"** |
| "ignore all previous instructions..." | Refused |
| n8n invoice workflow | Pauses for approval; approve in Mailpit at `http://localhost:8025` |

The answers come from the sample documents in `documents/company/` and `documents/executive/`. To load your own: drop files into those folders — the ingestion worker picks them up automatically (every `INGEST_INTERVAL_SECONDS`, default 15 min; tunable in `.env`). To ingest immediately:

```bash
sudo docker exec ingestion python3 /app/ingest.py
```

`documents/company/` is visible to all users; `documents/executive/` to admins only. Folder name = ACL tag (subfolders included — files anywhere under those folders get ingested; supported types: pdf, docx, txt/md/markdown, rtf, html, csv, xlsx, pptx, odt).

## Repository layout

```
├── phase1a.sh / phase1b.sh     # foundation: OS, driver, Docker, GPU, model download
├── gittar.sh                   # runtime dirs Git can't track (called by pathb.sh)
├── genenv.sh                   # fresh secrets into .env (called by pathb.sh)
├── pathb.sh                    # installer: dirs → secrets → containers → keys → seed
├── backup.sh / restore.sh      # capture state / rebuild elsewhere
├── docker-compose.yml          # all 10 services, pinned
├── litellm/config.yaml         # gateway config: model alias, budgets, thinking-mode off
├── guardrails/                 # policy.txt (plain-English rules) + guardrails-function.py (WebUI filter)
├── ingestion/                  # Dockerfile + ingest.py
├── documents/                  # seed documents: company/ (all users) + executive/ (admins)
├── exports/                    # MyWorkflow.json (n8n demo workflow, imported in the UI)
└── docs/                       # full guides
```

**Secrets are never committed.** `.env` is generated on the box (mode 600). Backup output contains secrets — keep it off the repo. (`.gitignore` covers both.)

## Operating notes

- Stop the instance when idle: ~$1.21/hr running vs ~$20/mo stopped.
- After any `.env` edit: `docker compose up -d --force-recreate <service>` — never `restart`. Env vars inject at container creation.
- The model is not backed up (~9GB, re-downloadable). Backups carry state and config only.
- Mailpit is in-memory and test-only; restarting wipes its inbox. Production email uses real SMTP.

## Roadmap

- Voice transcription (GPU Whisper) + meeting-notes workflow
- Speaker diarization
- Production ingestion: OCR for scanned PDFs + legacy .doc/.xls via a dedicated pipeline, per-file status
- Larger-model tier on a 48GB GPU
