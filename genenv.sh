#!/usr/bin/env bash
# genenv.sh — generate a FRESH .env for a fresh install.
# Secrets are BORN here (openssl rand), never typed or carried.
# The two sk- virtual keys are minted later by pathb.sh from a live LiteLLM.
set -euo pipefail
STACK=/opt/ai-stack

gen() { openssl rand -hex 24; }   # 48 hex chars, URL-safe

LLAMA=$(gen); PGPASS=$(gen); WEBUISEC=$(gen); QDRANT=$(gen); N8NENC=$(gen)

sudo tee "$STACK/.env" >/dev/null <<EOF
LLAMA_API_KEY=$LLAMA

# --- Section 3: LiteLLM gateway ---
LITELLM_MASTER_KEY=sk-$(gen)
POSTGRES_USER=litellm
POSTGRES_DB=litellm
POSTGRES_PASSWORD=$PGPASS
DATABASE_URL=postgresql://litellm:$PGPASS@postgres:5432/litellm

# --- Section 4: Open WebUI ---
WEBUI_VIRTUAL_KEY=PENDING_MINT
WEBUI_SECRET_KEY=$WEBUISEC

# --- Section 5: Document brain (RAG) ---
QDRANT_API_KEY=$QDRANT

# --- Section 6: n8n workflows ---
N8N_VIRTUAL_KEY=PENDING_MINT
N8N_ENCRYPTION_KEY=$N8NENC
EOF
sudo chmod 600 "$STACK/.env"
sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$STACK/.env"

# verify: 11 keys, none empty
# (the count pattern must include 0-9 or the digit-bearing N8N_* keys don't count)
MISSING=$(sudo grep -cE '=$' "$STACK/.env" || true)
COUNT=$(sudo grep -cE '^[A-Z0-9_]+=' "$STACK/.env" || true)
echo "genenv: wrote $STACK/.env (mode 600). keys=$COUNT empty=$MISSING"
[[ "$COUNT" -ge 11 && "$MISSING" -eq 0 ]] || { echo "ERROR: env incomplete"; exit 1; }
