#!/usr/bin/env bash
# pathb.sh — fresh install orchestrator: no backup, fresh secrets.
# Runs AFTER phase1a + reboot + phase1b, on a box with the kit untarred at /opt/ai-stack.
set -euo pipefail
STACK=/opt/ai-stack
log(){ echo "== $*"; }

# --- gate ---
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

# --- wait for the LLM backend: containers up ≠ model loaded (first boot maps ~9GB) ---
# Probe from INSIDE ai-net via the litellm container (ships python3) — the exact path
# production uses. Indifferent to whether host port 8080 is published (lock-down).
log "waiting for llamacpp model-ready (probe from inside ai-net)"
LLAMA_KEY=$(grep '^LLAMA_API_KEY=' "$STACK/.env" | cut -d= -f2-)
READY=0
for i in $(seq 1 90); do
  if docker exec litellm python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://llamacpp:8080/health', headers={'Authorization': 'Bearer $LLAMA_KEY'}), timeout=5)" >/dev/null 2>&1; then READY=1; break; fi
  sleep 5
done
if [[ "$READY" == 1 ]]; then
  log "llamacpp model-ready"
else
  log "WARNING: model still loading after the wait — first chats may fail briefly; watch: docker logs llamacpp"
fi

MASTER=$(grep '^LITELLM_MASTER_KEY=' "$STACK/.env" | cut -d= -f2)

mint(){ # mints a company-ai virtual key, prints the sk- value
  curl -sf -X POST http://localhost:4000/key/generate \
    -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d '{"models":["company-ai"]}' | jq -r .key
}
log "minting WebUI + n8n virtual keys"
WK=$(mint); NK=$(mint)
[[ "$WK" == sk-* && "$NK" == sk-* ]] || { echo "ERROR: key minting failed (jq returned empty — is LiteLLM really up?)"; exit 1; }

# --- inject minted keys, force-recreate so they take effect ---
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
# NOTE: the model-ready wait above means VRAM should already read ~16,6xx here.
# ~3,1xx = the wait timed out; the model is still loading (check: docker logs llamacpp).
log "containers: $(docker ps -q | wc -l)/10"
VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)
log "VRAM used: ${VRAM} MiB (norm ~16,6xx; over ~21,000 = watch the GPU budget)"

cat <<DONE

  STACK IS UP — fresh secrets, minted keys, documents seeded into company_docs.

  NOW THE BROWSER WIRING (see the guide, Stage 3):
    1. WebUI  http://localhost:3000  → create admin (first account = admin)
    2. WebUI  → Admin → Settings → Authentication → turn OFF "Allow New Signups" → Save
    3. WebUI  → verify model dropdown shows company-ai (compose pre-wires the connection)
    4. WebUI  → Admin → Functions → import guardrails-function.py → enable + set GLOBAL → Valves: paste Qdrant key
    5. n8n    http://localhost:5678  → create owner
    6. n8n    → OpenAI credential (base http://litellm:4000/v1, key = N8N_VIRTUAL_KEY from .env)
    7. n8n    → SMTP credential (mailpit:1025, test/test, TLS off)
    8. n8n    → Import MyWorkflow.json → confirm both credentials referenced

  Then verify: mileage=67c (any user) · CEO salary=\$425,000 (admin) · salary refused (regular user) ·
               injection refused · invoice workflow → Mailpit → Approve.

DONE
