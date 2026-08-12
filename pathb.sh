#!/usr/bin/env bash
# pathb.sh — Path B orchestrator: fresh install, no backup, fresh secrets.
# Runs AFTER phase1a + reboot + phase1b, on a box with the kit untarred at /opt/ai-stack.
# Field-corrected against build_3..8 (the real §3-§8 guides).
set -euo pipefail
STACK=/opt/ai-stack
log(){ echo "== $*"; }

# --- gate (restore.sh [0/8] checks) ---
command -v docker >/dev/null || { echo "ERROR: docker missing — run phase1b"; exit 1; }
nvidia-smi >/dev/null 2>&1  || { echo "ERROR: GPU not ready — phase1a/reboot"; exit 1; }
docker network inspect ai-net >/dev/null 2>&1 || docker network create ai-net
GGUF=$(ls "$STACK"/models/*.gguf 2>/dev/null | head -1)
[[ -n "$GGUF" && "$(head -c4 "$GGUF")" == "GGUF" ]] || { echo "ERROR: model GGUF missing/invalid — phase1b"; exit 1; }
[[ -f "$STACK/docker-compose.yml" ]] || { echo "ERROR: kit not untarred to $STACK"; exit 1; }
log "gate passed: docker/GPU/ai-net/model/kit all present"

# --- prepare runtime dirs Git can't track (empty dirs, permissions) ---
log "running gittar (runtime dirs, permissions)"
bash "$STACK/gittar.sh"

# --- fresh secrets ---
log "generating fresh .env (secrets born on this box)"
bash "$STACK/genenv.sh"

# --- build ingestion image + bring stack up (first boot: 141 migrations) ---
log "building ingestion image"
docker build -t ai-stack-ingestion "$STACK/ingestion"
log "bringing stack up (LiteLLM will run 141 migrations — give it a minute)"
cd "$STACK" && docker compose up -d

# --- wait for LiteLLM, then mint the two virtual keys ---
log "waiting for LiteLLM to be alive"
for i in $(seq 1 60); do curl -sf http://localhost:4000/health/liveliness >/dev/null 2>&1 && break; sleep 2; done
MASTER=$(grep '^LITELLM_MASTER_KEY=' "$STACK/.env" | cut -d= -f2)

mint(){ # mints a company-ai virtual key, prints the sk- value
  curl -sf -X POST http://localhost:4000/key/generate \
    -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d '{"models":["company-ai"]}' | jq -r .key
}
log "minting WebUI + n8n virtual keys"
WK=$(mint); NK=$(mint)
[[ "$WK" == sk-* && "$NK" == sk-* ]] || { echo "ERROR: key minting failed (jq returned empty — is LiteLLM really up?)"; exit 1; }

# --- inject minted keys, force-recreate so they take effect (Bug 33/34) ---
sed -i "s|^WEBUI_VIRTUAL_KEY=.*|WEBUI_VIRTUAL_KEY=$WK|" "$STACK/.env"
sed -i "s|^N8N_VIRTUAL_KEY=.*|N8N_VIRTUAL_KEY=$NK|" "$STACK/.env"
log "keys injected; force-recreating webui + n8n"
docker compose up -d --force-recreate open-webui n8n

# --- wait for TEI, then seed Qdrant (single collection company_docs; folder name = acl tag) ---
log "waiting for embeddings Ready"
for i in $(seq 1 72); do docker logs embeddings 2>&1 | grep -q Ready && break; sleep 5; done
docker compose up -d ingestion   # insurance: ingestion has no restart policy in some composes
log "seeding Qdrant (collection: company_docs; acl from folder name)"
docker exec ingestion python3 /app/ingest.py

# --- canary + VRAM note ---
log "containers: $(docker ps -q | wc -l)/10"
VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
log "VRAM used: ${VRAM} MiB (field norm ~16,6xx; over ~21,000 = watch Bug 25)"

cat <<DONE

  PATH B STACK IS UP — fresh secrets, minted keys, documents seeded into company_docs.

  NOW THE 4 BROWSER STOPS (the part that needs a human):
    1. WebUI  http://localhost:3000  → create admin (first account = admin)
    2. WebUI  → Admin → Settings → General → turn OFF "Allow New Signups" → Save
    3. WebUI  → Admin → Functions → import guardrails-function.py → enable + set GLOBAL (Bug 50) → Valves: paste Qdrant key
    4. n8n    http://localhost:5678  → create owner → Import MyWorkflow.json → add OpenAI credential
              (base http://litellm:4000/v1, key = N8N_VIRTUAL_KEY from .env)

  Then verify: mileage=67c (any user) · CEO salary=\$425,000 (admin) · salary refused (regular user) ·
               injection refused · invoice workflow → Mailpit → Approve.

DONE
