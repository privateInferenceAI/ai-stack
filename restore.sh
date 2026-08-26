#!/usr/bin/env bash
#
# AI stack — restore from backup.
# Usage: sudo ./restore.sh /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
#
# Restores config + all data stores from a backup made by backup.sh.
# Designed to be extended for a fresh-server clone (see CLONE HOOKS below).
#
set -euo pipefail

# ---------- args & sanity ----------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backup-directory>"
  echo "Example: $0 /opt/ai-stack/backups/ai-stack-backup-20260807-233149"
  exit 1
fi

BACKUP="$1"
STACK=/opt/ai-stack

if [[ ! -d "$BACKUP" ]]; then
  echo "ERROR: backup directory not found: $BACKUP"
  exit 1
fi

if [[ ! -f "$BACKUP/config/docker-compose.yml" ]]; then
  echo "ERROR: $BACKUP does not look like a backup (missing config/docker-compose.yml)"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run with sudo (data volumes are owned by container UIDs)"
  exit 1
fi

echo "=================================================="
echo " AI STACK RESTORE"
echo " Backup: $BACKUP"
echo " Target: $STACK"
echo "=================================================="
echo "This will STOP the stack and OVERWRITE current state."
read -r -p "Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ---------- 1. stop the stack ----------
echo
echo "[1/7] Stopping stack (if running)..."
if [[ -f "$STACK/docker-compose.yml" ]]; then
  (cd "$STACK" && docker compose down) || echo "  (stack was not fully up — continuing)"
else
  echo "  (no existing compose file — fresh target)"
fi

# ---------- 2. restore config ----------
echo
echo "[2/7] Restoring config files..."
mkdir -p "$STACK"
cp "$BACKUP/config/docker-compose.yml" "$STACK/docker-compose.yml"
cp "$BACKUP/config/env" "$STACK/.env"
chmod 600 "$STACK/.env"
[[ -d "$BACKUP/config/litellm" ]]    && cp -r "$BACKUP/config/litellm" "$STACK/"
[[ -d "$BACKUP/config/guardrails" ]] && cp -r "$BACKUP/config/guardrails" "$STACK/"
[[ -f "$BACKUP/config/ingest.py" ]]  && { mkdir -p "$STACK/ingestion"; cp "$BACKUP/config/ingest.py" "$STACK/ingestion/"; }
[[ -f "$BACKUP/config/Dockerfile" ]] && { mkdir -p "$STACK/ingestion"; cp "$BACKUP/config/Dockerfile" "$STACK/ingestion/"; }
echo "  config restored (.env mode 600)"

# CLONE HOOK (fresh server): here is where you'd ensure the foundation exists —
# Docker, NVIDIA toolkit, the ai-net network, and the model GGUF download.
# e.g.:  docker network inspect ai-net >/dev/null 2>&1 || docker network create ai-net
#        [[ -f "$STACK/models/Qwen3-14B-Q4_K_M.gguf" ]] || hf download Qwen/Qwen3-14B-GGUF ...

# ---------- 3. restore Postgres dump ----------
echo
echo "[3/7] Restoring Postgres (LiteLLM keys/budgets/logs)..."
# Postgres must be running to accept the restore. Bring up only postgres first.
(cd "$STACK" && docker compose up -d postgres)
echo "  waiting for postgres to accept connections..."
for i in $(seq 1 30); do
  if docker exec litellm-postgres pg_isready -U litellm -d litellm >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# --- Sync the role password to the restored .env ---
# Needed on a WARM target (this box previously ran a stack): the existing
# postgres-data was initialized under the OLD .env password, and database dumps
# don't carry role passwords — so the restored .env's DATABASE_URL wouldn't match
# the live role. Harmless no-op on a fresh target (passwords match by construction).
# Works because psql inside the container over the local socket is trust-authenticated.
echo "  syncing postgres role password to restored .env..."
PGPW=$(grep '^POSTGRES_PASSWORD=' "$STACK/.env" | cut -d= -f2-)
docker exec litellm-postgres psql -h /var/run/postgresql -U litellm -d postgres \
  -c "ALTER USER litellm WITH PASSWORD '$PGPW';"

# Drop and recreate the litellm DB so the dump restores into a clean database.
docker exec litellm-postgres psql -U litellm -d postgres -c "DROP DATABASE IF EXISTS litellm;"
docker exec litellm-postgres psql -U litellm -d postgres -c "CREATE DATABASE litellm;"
docker exec -i litellm-postgres psql -U litellm -d litellm < "$BACKUP/postgres-litellm.sql"
echo "  postgres restored"

# ---------- 4. restore Qdrant ----------
echo
echo "[4/7] Restoring Qdrant data..."
rm -rf "$STACK/qdrant-data"
tar xzf "$BACKUP/qdrant-data.tar.gz" -C "$STACK"
echo "  qdrant restored"

# ---------- 5. restore WebUI data ----------
echo
echo "[5/7] Restoring WebUI data..."
rm -rf "$STACK/open-webui-data"
tar xzf "$BACKUP/open-webui-data.tar.gz" -C "$STACK"
echo "  webui restored"

# ---------- 6. restore n8n data ----------
echo
echo "[6/7] Restoring n8n data..."
rm -rf "$STACK/n8n-data"
tar xzf "$BACKUP/n8n-data.tar.gz" -C "$STACK"
chown -R 1000:1000 "$STACK/n8n-data"   # n8n runs as UID 1000 (Bug 23 rule)
echo "  n8n restored"

# ---------- 7. restore documents + exports ----------
echo
echo "[7/7] Restoring documents and exports..."
[[ -f "$BACKUP/documents.tar.gz" ]] && { rm -rf "$STACK/documents"; tar xzf "$BACKUP/documents.tar.gz" -C "$STACK"; }
[[ -f "$BACKUP/exports.tar.gz" ]]   && { rm -rf "$STACK/exports";   tar xzf "$BACKUP/exports.tar.gz"   -C "$STACK"; }
echo "  documents + exports restored"

# ---------- bring the stack up ----------
echo
echo "Bringing the stack up..."
(cd "$STACK" && docker compose up -d)

echo
echo "=================================================="
echo " Restore complete. Verify with:"
echo "   docker ps --format '{{.Names}}\\t{{.Status}}'"
echo "   curl -s http://localhost:4000/health/liveliness"
echo "=================================================="
echo "NOTE: on a fresh server you may still need to:"
echo "  - re-download the model (hf download ...)"
echo "  Accounts come back WITH the data (WebUI/n8n/LiteLLM all restored)."
echo "  Just log in. The 're-create accounts' note was killed by the 2026-08-09 clone."
