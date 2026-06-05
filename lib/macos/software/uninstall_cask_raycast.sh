#!/bin/bash
# Uninstall script pour Raycast (Cask : raycast, via sp-installer)

set -uo pipefail

SERVICE_USER="sp-installer"
CASK_NAME="raycast"
LOG="/var/log/cask_${CASK_NAME}_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "=== Cask uninstall : $CASK_NAME ==="

cd /tmp || cd /

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "[ERROR] $SERVICE_USER n'existe pas"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
else
    BREW_BIN="/usr/local/bin/brew"
fi

if [ ! -x "$BREW_BIN" ]; then
    log "Homebrew absent, rien à faire"
    exit 0
fi

if sudo -u "$SERVICE_USER" -H "$BREW_BIN" list --cask "$CASK_NAME" >/dev/null 2>&1; then
    log "Désinstallation de $CASK_NAME..."
    sudo -u "$SERVICE_USER" -H "$BREW_BIN" uninstall --cask --zap "$CASK_NAME" >> "$LOG" 2>&1 || {
        log "[WARN] --zap a échoué, fallback simple"
        sudo -u "$SERVICE_USER" -H "$BREW_BIN" uninstall --cask "$CASK_NAME" >> "$LOG" 2>&1 || true
    }
else
    log "$CASK_NAME pas installé"
fi

log "=== Uninstall done ==="
exit 0
