#!/usr/bin/env bash
#
# Phase 1a — fresh-server foundation, PART 1 (pre-reboot).
# System update, timezone, NVIDIA driver (with known-good vs recommended choice).
# Run this FIRST on a clean Ubuntu 24.04 box. Reboot when it tells you to, then run phase1b.sh.
#
set -euo pipefail

KNOWN_GOOD_DRIVER="nvidia-driver-595"   # the driver series the original build was tested on
STACK=/opt/ai-stack
LOG="$STACK/install-log.txt"
OWNER="${SUDO_USER:-$USER}"             # correct whether run as ./phase1a.sh or sudo ./phase1a.sh

sudo mkdir -p "$STACK"
sudo touch "$LOG"
sudo chown -R "$OWNER:$OWNER" "$STACK"

log() {
  echo "$1"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $1" | sudo tee -a "$LOG" >/dev/null
}

log "=== Phase 1a start (foundation, pre-reboot) ==="

# --- 1. System update + baseline ---
log "Running apt update/upgrade (this can take a few minutes)..."
sudo apt update && sudo apt upgrade -y
sudo timedatectl set-timezone UTC
sudo apt install -y unattended-upgrades curl ca-certificates gnupg
log "System updated; timezone set to UTC; unattended-upgrades installed."

# --- 2. NVIDIA driver (with known-good vs recommended choice) ---
log "Installing ubuntu-drivers-common..."
sudo apt install -y ubuntu-drivers-common

RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep -i 'recommended' | grep -oiE 'nvidia-driver-[0-9]+' | head -1 || true)

if [[ -z "$RECOMMENDED" ]]; then
  log "WARNING: could not parse a recommended driver automatically."
  ubuntu-drivers devices || true
  echo
  read -r -p "No recommended driver detected. Install known-good ${KNOWN_GOOD_DRIVER}? [y/n]: " KG
  if [[ "$KG" =~ ^[Yy]$ ]]; then
    CHOSEN_DRIVER="$KNOWN_GOOD_DRIVER"
  else
    echo "Aborting driver install. Install a driver manually, then re-run phase1a."
    exit 1
  fi
elif [[ "$RECOMMENDED" == "$KNOWN_GOOD_DRIVER" ]]; then
  log "Recommended driver (${RECOMMENDED}) matches known-good. Using it."
  CHOSEN_DRIVER="$RECOMMENDED"
else
  echo "=================================================="
  echo " DRIVER CHOICE"
  echo "   Recommended now : ${RECOMMENDED}"
  echo "   Known-good build: ${KNOWN_GOOD_DRIVER}"
  echo "=================================================="
  read -r -p "Install [R]ecommended or [K]nown-good? [R/k]: " PICK
  if [[ "$PICK" =~ ^[Kk]$ ]]; then
    CHOSEN_DRIVER="$KNOWN_GOOD_DRIVER"
  else
    CHOSEN_DRIVER="$RECOMMENDED"
  fi
fi

log "Driver selected for install: ${CHOSEN_DRIVER}"

if [[ "$CHOSEN_DRIVER" == "$KNOWN_GOOD_DRIVER" && "$RECOMMENDED" != "$KNOWN_GOOD_DRIVER" ]]; then
  log "Installing pinned known-good driver: ${CHOSEN_DRIVER}"
  sudo apt install -y "$CHOSEN_DRIVER"
else
  log "Installing recommended driver via autoinstall."
  sudo ubuntu-drivers autoinstall
fi

INSTALLED_NOTE=$(apt-cache policy "$CHOSEN_DRIVER" 2>/dev/null | grep -i 'installed' || echo "see autoinstall")
log "Driver install step complete. ${INSTALLED_NOTE}"

log "=== Phase 1a complete ==="
echo
echo "=================================================="
echo " PHASE 1a DONE."
echo " The NVIDIA driver needs a reboot to load."
echo " Run:  sudo reboot"
echo " Then SSH back in and run:  ./phase1b.sh"
echo "=================================================="
