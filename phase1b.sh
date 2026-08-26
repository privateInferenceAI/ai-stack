#!/usr/bin/env bash
#
# Phase 1b — fresh-server foundation, PART 2 (post-reboot).
# Docker, NVIDIA Container Toolkit, firewall, fail2ban, dir tree, ai-net, model download, verification.
# Run this AFTER the reboot that follows phase1a.sh.
# Safe to invoke as ./phase1b.sh or sudo ./phase1b.sh — user-level steps target the real user either way.
#
set -euo pipefail

STACK=/opt/ai-stack
LOG="$STACK/install-log.txt"
OWNER="${SUDO_USER:-$USER}"                          # the real user, even under sudo
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)   # owner's home, not root's

log() {
  echo "$1"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $1" | sudo tee -a "$LOG" >/dev/null
}

log "=== Phase 1b start (post-reboot) ==="

# --- 0. Verify the driver loaded before doing anything GPU-dependent ---
if ! nvidia-smi >/dev/null 2>&1; then
  log "ERROR: nvidia-smi not working. Driver did not load. Check the driver install, then re-run phase1b."
  exit 1
fi
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "unknown")
log "GPU detected: ${GPU_NAME} | driver ${DRIVER_VER}"

# --- 1. Docker (official repo, literal codename) ---
log "Installing Docker from the official repo..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$OWNER"
log "Docker installed. NOTE: docker group membership for ${OWNER} needs a fresh login (or 'newgrp docker') to work without sudo."

# --- 2. NVIDIA Container Toolkit ---
log "Installing NVIDIA Container Toolkit..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
log "Container toolkit installed and Docker restarted."

# --- 3. Firewall + fail2ban ---
log "Configuring UFW + fail2ban..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo apt install -y fail2ban jq
printf '[sshd]\nenabled = true\nbackend = systemd\n' | sudo tee /etc/fail2ban/jail.d/sshd.local
sudo systemctl enable --now fail2ban
log "Firewall active (SSH only inbound); fail2ban running (systemd backend)."

# --- 4. Stack directory tree + Docker network ---
log "Creating stack tree + ai-net network..."
sudo mkdir -p "$STACK/models"
sudo touch "$STACK/.env"
sudo chmod 600 "$STACK/.env"
sudo chown -R "$OWNER:$OWNER" "$STACK"

if sudo docker network inspect ai-net >/dev/null 2>&1; then
  log "ai-net already exists."
else
  sudo docker network create ai-net
  log "ai-net created."
fi

# --- 5. Model downloads (models are NOT in backups — re-download on fresh boxes) ---
# hf CLI: user-level pip install; all downloads run as the real user, not root.
sudo apt install -y python3-pip
sudo -u "$OWNER" env HOME="$OWNER_HOME" python3 -m pip install --user --break-system-packages huggingface_hub
HF_BIN="$OWNER_HOME/.local/bin/hf"
if [[ ! -x "$HF_BIN" && -x "$OWNER_HOME/.local/bin/huggingface-cli" ]]; then
  HF_BIN="$OWNER_HOME/.local/bin/huggingface-cli"
fi

# 5a. LLM GGUF
MODEL="$STACK/models/Qwen3-14B-Q4_K_M.gguf"
if [[ -f "$MODEL" ]] && head -c 4 "$MODEL" 2>/dev/null | grep -q GGUF; then
  log "Model already present and valid, skipping download."
else
  log "Downloading Qwen3-14B Q4_K_M (~9GB, this is the long pole)..."
  sudo -u "$OWNER" env HOME="$OWNER_HOME" "$HF_BIN" download Qwen/Qwen3-14B-GGUF Qwen3-14B-Q4_K_M.gguf --local-dir "$STACK/models"
fi
if head -c 4 "$MODEL" 2>/dev/null | grep -q GGUF; then
  log "Model verified (GGUF header present)."
else
  log "WARNING: model file missing or header check failed. Check $MODEL before proceeding."
fi

# 5b. TEI models (embeddings + reranker) — pre-downloaded into an HF cache at
# $STACK/models/tei, mounted at /data in the TEI containers (which also run with
# HF_HUB_OFFLINE=1). Without this, TEI downloads from HuggingFace at first boot —
# which may be an offline client LAN — and re-downloads on every container recreate.
for REPO in BAAI/bge-m3 BAAI/bge-reranker-v2-m3; do
  NAME="${REPO##*/}"
  SNAP="$STACK/models/tei/models--${REPO/\//--}/snapshots"
  if compgen -G "$SNAP/*/model.safetensors" >/dev/null || compgen -G "$SNAP/*/pytorch_model.bin" >/dev/null; then
    log "TEI model $NAME already cached, skipping."
  else
    log "Downloading TEI model $REPO..."
    sudo -u "$OWNER" env HOME="$OWNER_HOME" HF_HUB_CACHE="$STACK/models/tei" "$HF_BIN" download "$REPO"
  fi
done

# --- 6. Verification summary ---
log "=== Phase 1b verification ==="
GPU_IN_CONTAINER=$(sudo docker run --rm --gpus all nvidia/cuda:13.2.0-base-ubuntu24.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo "FAILED")
log "GPU visible inside a container: ${GPU_IN_CONTAINER}"
if [[ "$GPU_IN_CONTAINER" == "FAILED" ]]; then
  log "HINT: a FAILED here can mean the CUDA test image tag moved, not a broken toolkit. The stack's real containers are the true GPU test."
fi
log "Docker version: $(sudo docker --version 2>/dev/null || echo 'n/a')"
log "Compose version: $(sudo docker compose version 2>/dev/null || echo 'n/a')"
log "Driver (host): ${DRIVER_VER}"
log "TEI cache: $(ls "$STACK/models/tei" 2>/dev/null | tr '\n' ' ')"

log "=== Phase 1b complete ==="
echo
echo "=================================================="
echo " PHASE 1b DONE. Foundation is ready."
echo " GPU in container: ${GPU_IN_CONTAINER}"
echo " Driver: ${DRIVER_VER}"
echo " Log written to: ${LOG}"
echo ""
echo " NEXT (fresh install):  untar the kit, then sudo bash /opt/ai-stack/pathb.sh"
echo " NEXT (restore):        sudo /opt/ai-stack/restore.sh /opt/ai-stack/backups/<backup-dir>"
echo "=================================================="
echo " NOTE: log out and back in (or run 'newgrp docker') so docker works without sudo."
