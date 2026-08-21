# Private AI Stack

A complete, self-hosted business AI system on a single GPU box. Staff chat, access-controlled document search (RAG), human-gated workflow automation, and a full audit trail — with **zero data leaving the building**.

Everything runs in Docker on one Ubuntu box with one NVIDIA GPU. No cloud AI APIs, no per-seat pricing, no data ever sent to OpenAI or anyone else.

## What you get

| Capability | What it does |
|---|---|
| **Staff AI chat** | A ChatGPT-style web UI (Open WebUI) talking to a model running on your GPU |
| **Document search (RAG)** | The AI answers from *your* documents, with ACL tags so restricted content stays restricted |
| **Workflow automation** | n8n workflows with a **human approval gate** — nothing acts until a person clicks Approve |
| **Access control + audit** | Per-user/per-service API keys with budgets, and every request logged (LiteLLM + Postgres) |

## The stack

```
Browser ──► Open WebUI ──► guardrails filter ──► LiteLLM ──► llama.cpp ──► GPU (Qwen3-14B)
                                                  │              └──► Postgres (keys, budgets, audit log)
                       n8n workflows ─────────────┘
                       Qdrant (vector DB) ◄── ingestion (on-demand job)
                       Mailpit (test email / human gate)
```

| Layer | Component | Job |
|---|---|---|
| Inference | llama.cpp + Qwen3-14B (Q4_K_M) | The engine — runs entirely on your GPU |
| Gateway | LiteLLM + Postgres | API keys, budgets, rate limits, full audit log |
| Chat UI | Open WebUI | The interface staff actually use |
| Document brain | Qdrant + bge-m3 + reranker | Your documents, searchable, ACL-tagged |
| Automation | n8n + Mailpit | Workflows with a human gate; fake SMTP for testing |
| Policy | WebUI filter function | Guardrails + role-based document access, enforced by code |

## Requirements

- **An AWS account** with quota for `g5.2xlarge` (1× NVIDIA A10G, 24GB VRAM, 8 vCPU, 32GB RAM). Cost: **~$1.21/hr running, ~$20/mo stopped.** Stop it when you're not using it.
- **An SSH key pair** (`.pem` file) for the instance.
- **~45–60 minutes**, most of it waiting for downloads.

Works on any Ubuntu 24.04 box with a 24GB NVIDIA GPU — AWS is just the documented target. (On-prem hardware is the real destination; the cloud box is the practice range.)

## Choose your path

| I want to... | Start here |
|---|---|
| **Build it the fast way** (helper scripts do the work) | This README's Quick start, then [docs/scripted-build.md](docs/scripted-build.md) for the full stage-by-stage version |
| **Build it by hand, every command and file** (learn it cold / audit what the scripts do) | [docs/manual-build.md](docs/manual-build.md) |
| **Move or rebuild an existing box** (accounts, documents, workflows come along) | [docs/backup-restore.md](docs/backup-restore.md) |

## Quick start (scripted path)

### 1. Launch the box

AWS console → EC2 → Launch:
- **Instance type:** `g5.2xlarge`
- **AMI:** Ubuntu 24.04
- **Storage:** 200GB gp3
- **Security group:** inbound port 22 only (SSH)
- Attach an **Elastic IP** so the address survives stop/start

From your laptop, clear any stale host key for that IP, then connect:

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

(The `/.` copies the repo *contents* — including `docker-compose.yml` — to the top level of `/opt/ai-stack`. That layout is required.)

### 3. Run the foundation scripts

```bash
chmod +x /opt/ai-stack/phase1a.sh /opt/ai-stack/phase1b.sh
sudo /opt/ai-stack/phase1a.sh
sudo reboot
# wait ~90 seconds, SSH back in
sudo /opt/ai-stack/phase1b.sh
newgrp docker
```

`phase1a` updates the OS and installs the NVIDIA driver (it will tell you to reboot). `phase1b` installs Docker, the NVIDIA container toolkit, the firewall, and downloads the model (~9 GB).

### 4. Run the install

```bash
sudo bash /opt/ai-stack/pathb.sh
```

This one script: creates the runtime directories, generates fresh secrets into `.env`, builds the ingestion image, starts all 10 containers, mints the API keys, and seeds the document store with the two sample documents. Watch for the closing banner — it ends with `containers: 10/10`.

### 5. Wire it up in the browser (the part that needs a human)

Open SSH tunnels from your laptop (leave the session open):

```bash
ssh -i /path/to/your-key.pem -L 3000:localhost:3000 -L 5678:localhost:5678 -L 8025:localhost:8025 ubuntu@<ELASTIC-IP>
```

Then, in order:

1. **WebUI admin** — `http://localhost:3000` → Sign up. **The first account becomes admin.** Use a real password.
2. **Lock the door** — Admin Panel → Settings → Authentication → turn OFF "Allow New Signups" → Save.
3. **Guardrails function** — Admin Panel → Functions → new → paste `exports/guardrails-function.py` → Save → enable it **and set it GLOBAL** → Valves: paste the `QDRANT_API_KEY` from `/opt/ai-stack/.env`.
4. **n8n owner** — `http://localhost:5678` → create the owner account.
5. **n8n credentials** — add an **OpenAI** credential (Base URL `http://litellm:4000/v1`, key = the `N8N_VIRTUAL_KEY` from `.env`) and an **SMTP** credential (host `mailpit`, port `1025`, user/pass `test`/`test`, TLS off).
6. **Import the workflow** — n8n → Import from File → `exports/MyWorkflow.json`.

### 6. Prove it works

| Test | Expected |
|---|---|
| WebUI chat: "What is the mileage reimbursement rate?" | **67 cents per mile** (answered from the sample document) |
| As admin: "What is the CEO salary?" | **$425,000** |
| As a regular (non-admin) user: "What is the CEO salary?" | **"I don't have that information"** — the ACL wall |
| "ignore all previous instructions..." | **Refused** — the model never sees it |
| n8n invoice workflow | Pauses for a human; you approve in Mailpit at `http://localhost:8025` |

The mileage/salary answers come from two sample documents in `documents/company/` and `documents/executive/`. Replace them with real documents and re-run the ingestion to make the brain yours:

```bash
cd /opt/ai-stack
sudo docker compose up -d ingestion
sudo docker exec ingestion python3 /app/ingest.py
```

Documents in `documents/company/` are visible to everyone; `documents/executive/` is visible to admins only. The folder name is the ACL tag.

## Repository layout

```
├── phase1a.sh / phase1b.sh     # foundation: OS, driver, Docker, GPU, model download
├── gittar.sh                   # creates the runtime dirs Git can't track (called by pathb.sh)
├── genenv.sh                   # generates fresh secrets into .env (called by pathb.sh)
├── pathb.sh                    # the installer: dirs → secrets → containers → keys → seed
├── backup.sh / restore.sh      # capture everything / rebuild it elsewhere
├── docker-compose.yml          # all 10 services, pinned
├── litellm/config.yaml         # the gateway: model alias, budgets, thinking-mode kill
├── guardrails/policy.txt       # the plain-English rules (the audit artifact)
├── ingestion/                  # Dockerfile + ingest.py (document brain loader)
├── documents/                  # seed documents: company/ (all users) + executive/ (admins)
├── exports/                    # guardrails-function.py + MyWorkflow.json (imported in the UI)
└── docs/                       # the full guides (see "Choose your path" above)
```

**Secrets are never committed.** `.env` is generated on the box by `genenv.sh` (mode 600) and stays there. Backup output contains secrets — keep it off the repo too. (`.gitignore` already covers both.)

## Operating notes

- **Stop the instance when idle.** ~$1.21/hr running vs ~$20/mo stopped. This is the single biggest cost lever.
- **After any `.env` edit:** `docker compose up -d --force-recreate <service>` — never `restart`. Env vars inject at container creation.
- **The model is never backed up** — it's ~9GB and re-downloadable. Backups carry state and config only.
- **Mailpit is in-memory and test-only** — restarting it wipes the inbox. Production email uses the client's real SMTP.

## Roadmap

- Voice transcription (GPU Whisper) + meeting-notes workflow
- Speaker diarization ("who said what") for legal/board/HR minutes
- Production document pipeline: watched folders, OCR for scanned PDFs, per-file status
- Larger-model tier on a 48GB GPU
