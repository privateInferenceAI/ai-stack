#!/usr/bin/env bash
# AI stack backup — captures all state needed to rebuild.
set -euo pipefail
STACK=/opt/ai-stack
TS=$(date +%Y%m%d-%H%M%S)
DEST=${1:-/opt/ai-stack/backups}
OUT="${DEST}/ai-stack-backup-${TS}"
mkdir -p "$OUT"
echo "Backing up to $OUT"

# 1. Config files
mkdir -p "$OUT/config"
cp "$STACK/docker-compose.yml" "$OUT/config/"
cp "$STACK/.env" "$OUT/config/env"
cp -r "$STACK/litellm" "$OUT/config/"
cp -r "$STACK/guardrails" "$OUT/config/"
cp "$STACK/ingestion/ingest.py" "$OUT/config/" 2>/dev/null || true
cp "$STACK/ingestion/Dockerfile" "$OUT/config/" 2>/dev/null || true

# 2. Postgres dump
echo "Dumping Postgres..."
docker exec litellm-postgres pg_dump -U litellm litellm > "$OUT/postgres-litellm.sql"

# 3. Qdrant snapshot
echo "Snapshotting Qdrant..."
sudo tar czf "$OUT/qdrant-data.tar.gz" -C "$STACK" qdrant-data

# 4. WebUI data
echo "Archiving WebUI data..."
sudo tar czf "$OUT/open-webui-data.tar.gz" -C "$STACK"  --exclude='open-webui-data/cache' open-webui-data
# sudo tar czf "$OUT/open-webui-data.tar.gz" -C "$STACK" open-webui-data --exclude='open-webui-data/cache' open-webui-data

# 5. n8n data
echo "Archiving n8n data..."
sudo tar czf "$OUT/n8n-data.tar.gz" -C "$STACK" n8n-data

# 6. Source documents
sudo tar czf "$OUT/documents.tar.gz" -C "$STACK" documents

# 7. Exports (n8n workflows, function code) — if present
sudo tar czf "$OUT/exports.tar.gz" -C "$STACK" exports 2>/dev/null || true

echo "Backup complete: $OUT"
du -sh "$OUT"
