#!/usr/bin/env bash
# gittar.sh — prepare a fresh clone of this repo for stack use.
# Git tracks files, not empty dirs or permissions. This script creates what Git can't.
# Run once after clone, before pathb.sh.
set -euo pipefail
STACK=/opt/ai-stack

echo "== gittar: creating runtime directories"
sudo mkdir -p "$STACK/models" "$STACK/postgres-data" "$STACK/open-webui-data" \
             "$STACK/qdrant-data" "$STACK/n8n-data" "$STACK/backups"

# n8n runs as UID 1000 (Bug 23 rule: chown n8n-data ONLY, never blanket-chown)
sudo chown -R 1000:1000 "$STACK/n8n-data"

# Everything else belongs to the deploying user
sudo chown -R "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$STACK"

# .env starts empty and locked; genenv.sh fills it
sudo touch "$STACK/.env"
sudo chmod 600 "$STACK/.env"
sudo chown "${SUDO_USER:-$USER}":"${SUDO_USER:-$USER}" "$STACK/.env"

echo "== gittar: done. Next: sudo bash $STACK/genenv.sh (or pathb.sh)"
