# PATH B — Fresh Install via Git (new secrets, new accounts)

**Use for:** a brand-new deployment on a local machine at a client site.
For cloning an existing box, use PATH-A-CLONE.md.
For practicing on AWS instead of local hardware, see the AWS subset at the bottom.

**The split:** everything deterministic is scripted; everything behind a first-login is a
numbered browser step. Secrets are BORN on the box (openssl) or MINTED by LiteLLM at
runtime — never typed, never carried, never in Git.

**Source of truth:** this repo. The technician's laptop needs only an SSH key for the
box and a GitHub token.

---

## STAGE 0 — PREREQUISITES (the physical box)

Hardware:
- A machine with an NVIDIA GPU with 24GB+ VRAM (this stack is field-proven on an A10G;
  an RTX 4090/A5000-class card also fits). 32GB+ RAM, 500GB+ SSD recommended.
- Ubuntu 24.04 Server installed, on the client's network, with a known IP
  (a static IP or DHCP reservation is strongly recommended — the box is a server).
- A user account with sudo (created during OS install).

You need on your laptop:
- SSH access to the box (key-based preferred)
- A GitHub **personal access token** with `repo` scope
  (GitHub → Settings → Developer settings → Personal access tokens)

Network note: the stack is reached via SSH tunnel, so no inbound firewall rules are
needed on the client network beyond the SSH access you already have. All app ports
(3000/4000/5678/8025) stay closed to the LAN; you reach them inside the tunnel.

---

## STAGE 1 — FOUNDATION (from the repo)

TERMINAL (box — SSH in as your sudo user):

```
sudo git clone https://<TOKEN>@github.com/privateInferenceAI/ai-stack.git /opt/ai-stack
sudo chmod +x /opt/ai-stack/*.sh
sudo /opt/ai-stack/phase1a.sh
sudo reboot
```

✔ phase1a ends clean; box reboots. Wait ~90s (a physical box may take longer — watch
the console or just keep retrying SSH).

TERMINAL (box — reconnect):

`sudo /opt/ai-stack/phase1b.sh`

✔ Docker + toolkit + UFW + ai-net + model download.
Verify: `head -c 4 /opt/ai-stack/models/*.gguf` prints `GGUF`.

Note: UFW allows OpenSSH only — on a LAN box this means the box accepts SSH and nothing
else inbound. That's intentional. Everything else rides inside SSH tunnels.

---

## STAGE 2 — DEPLOY

TERMINAL (box):

`sudo bash /opt/ai-stack/pathb.sh`

✔ EXPECTED, in order:
- `== gate passed` (docker/GPU/ai-net/model/compose)
- `== running gittar (runtime dirs, permissions)`  ← Git can't track empty dirs/perms
- `genenv: wrote .env (mode 600). keys=11 empty=0`  ← 11, not 9 (Bug 58)
- ingestion image builds (~40s), stack up (141 migrations, several min — DON'T interrupt)
- `== minting WebUI + n8n virtual keys` → force-recreate
- `== seeding Qdrant (collection: company_docs)` → OK chunks from both starter docs
- `== containers: 10/10` · VRAM ~16,6xx MiB
- The 4-browser-stop banner

If the gate fails → it names the missing piece. If `containers:` < 10 → `docker ps -a`,
last 3 lines of the dead one.

---

## STAGE 3 — THE MANUAL WIRING (browser — needs a human)

Open tunnels first (your laptop, on the client network or via their VPN — leave open):

`ssh user@<BOX-IP> -L 3000:localhost:3000 -L 5678:localhost:5678 -L 8025:localhost:8025`

1. **WebUI admin.** `http://localhost:3000` → Sign up → first account = ADMIN.
2. **Lock the door.** Admin → Settings → Authentication → signups OFF → Save.
3. **Connect the model.** Admin → Settings → Connections → OpenAI:
   `http://litellm:4000/v1` + raw WEBUI_VIRTUAL_KEY
   (`sudo grep '^WEBUI_VIRTUAL_KEY=' /opt/ai-stack/.env`). Model dropdown shows `company-ai`.
4. **Guardrail function.** Admin → Functions → new → paste `guardrails/guardrails-function.py`
   → Save → enable AND set GLOBAL (Bug 50) → Valves: paste QDRANT_API_KEY.
5. **n8n owner.** `http://localhost:5678` → create owner.
6. **n8n OpenAI credential.** Base `http://litellm:4000/v1`, key = raw N8N_VIRTUAL_KEY.
7. **n8n SMTP credential.** Host `mailpit`, port 1025, test/test, TLS off.
8. **Import workflow.** n8n → Import `exports/MyWorkflow.json` → wire both credentials.

---

## STAGE 4 — VERIFY (the 3 tests, using the committed starter fixtures)

1. **Chat chain.** Any question → normal answer, no scratch-work.
   `SELECT count(*) FROM "LiteLLM_SpendLogs";` grows.
2. **RAG + ACL.** mileage → 67¢ (everyone) · CEO salary → $425,000 (admin) ·
   refused (regular user) · injection → refused, no model call.
   Watch: `sudo docker logs -f open-webui` for `[guardrails] RAG injected ... acl=...`.
3. **Human-gated workflow.** Fresh invoice email (Mailpit is in-memory — send fresh
   each session) → n8n Execute → Mailpit `http://localhost:8025` → Approve → resumes.

All three pass = the build is proven. Anything else = check BUG-LOG.md first.

---

## STAGE 5 — CUSTOMIZE FOR THE CLIENT

The starter fixtures (documents, workflow, guardrails function) exist to prove the build.
Now swap in the client's reality:

```
cd /opt/ai-stack
sudo git checkout -b client-<name>
```

- Replace `documents/company/*` and `documents/executive/*` with real documents
- Re-ingest: `sudo docker exec ingestion python3 /app/ingest.py`
- Adjust `guardrails/policy.txt`, function valves, and the workflow as needed
- RULE: real PII / real salaries / real client-confidential content stays ON THE BOX,
  never committed. Client branches hold structure and config, not secrets.

---

## STAGE 6 — HANDOFF / LEAVE-RUNNING

A client box stays running — it's their server. Before you leave:
- Confirm unattended-upgrades is on (phase1a installs it)
- Confirm the box survives a reboot: `sudo reboot`, wait, `docker ps` → 10/10
  (compose `restart: unless-stopped` brings everything back)
- Hand the client their WebUI login; you keep SSH + the GitHub token
- Record the box in your inventory (IP, client, date, branch)

---

# APPENDIX — AWS PRACTICE SUBSET

**Use this only for practice/training builds on EC2.** Differences from the on-prem flow:

| Step | On AWS instead |
|---|---|
| Hardware | Launch g5.2xlarge, Ubuntu 24.04 AMI, SG inbound 22 only, 200GB gp3 |
| IP | Move your Elastic IP to the instance |
| Host key | `ssh-keygen -R <ELASTIC-IP>` on your laptop (IP reused on new silicon) |
| User | The AMI's default user is `ubuntu` |
| Stage 1–5 | Identical to the on-prem procedure above |
| Shutdown | **STOP the instance when done** — ~$1.21/hr running, ~$20/mo stopped |

Everything else — clone, phase1a/1b, pathb, browser wiring, tests — is the same.
The AWS box is a practice dummy that bills by the hour. The product is the on-prem box.

