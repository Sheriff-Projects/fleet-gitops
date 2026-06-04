#!/bin/bash
# Uninstall script pour Raycast (Homebrew Cask : raycast)

set -uo pipefail

CASK_NAME="raycast"
LOG="/var/log/cask_${CASK_NAME}_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "=== Cask uninstall : $CASK_NAME ==="

CONSOLE_USER=$(stat -f%Su /dev/console)
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    log "[ERROR] Pas d'user GUI"
    exit 1
fi
CONSOLE_UID=$(id -u "$CONSOLE_USER")

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

run_as_user() {
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"
}

if run_as_user "$BREW_BIN" list --cask "$CASK_NAME" >/dev/null 2>&1; then
    log "Désinstallation de $CASK_NAME..."
    run_as_user "$BREW_BIN" uninstall --cask --zap "$CASK_NAME" >> "$LOG" 2>&1 || {
        log "[WARN] uninstall --zap a échoué, fallback uninstall simple"
        run_as_user "$BREW_BIN" uninstall --cask "$CASK_NAME" >> "$LOG" 2>&1 || true
    }
else
    log "$CASK_NAME pas installé via Homebrew"
fi

log "=== Uninstall done ==="
exit 0
