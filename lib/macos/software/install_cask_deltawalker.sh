#!/bin/bash
# Install DeltaWalker via Homebrew Cask
# Build on 2026-06-08 20:08:52
# Cask : deltawalker (v2.8.1)
#
# Cet install_script est exécuté directement par Fleet (pas dans un postinstall
# de pkg). Si ça plante, l'erreur précise apparaît dans Fleet UI > Activity
# et dans /var/log/cask_<nom>_install.log.

set -uo pipefail

SERVICE_USER="sp-installer"
CASK_NAME="deltawalker"
APP_FILENAME=""

LOG="/var/log/cask_${CASK_NAME}_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "=== Cask install : $CASK_NAME (via $SERVICE_USER) ==="

cd /tmp || cd /

# -------------------------------------------------------------------------
# 1. Vérifier sp-installer
# -------------------------------------------------------------------------
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "[ERROR] Le compte $SERVICE_USER n'existe pas"
    log "Déploie create_service_admin.sh avant cet install."
    exit 1
fi

# -------------------------------------------------------------------------
# 2. Détecter arch + Homebrew
# -------------------------------------------------------------------------
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
    IS_INTEL=0
else
    BREW_PREFIX="/usr/local"
    IS_INTEL=1
fi
BREW_BIN="$BREW_PREFIX/bin/brew"

if [ ! -x "$BREW_BIN" ]; then
    log "[ERROR] Homebrew absent à $BREW_BIN"
    log "Déploie install_homebrew.sh AVANT cet install."
    exit 1
fi

# -------------------------------------------------------------------------
# 3. Vérifier l'ownership (Intel-aware)
# -------------------------------------------------------------------------
if [ "$IS_INTEL" = "1" ]; then
    OWNER_CHECK_DIR="$BREW_PREFIX/Homebrew"
else
    OWNER_CHECK_DIR="$BREW_PREFIX"
fi

if [ -d "$OWNER_CHECK_DIR" ]; then
    BREW_OWNER=$(stat -f%Su "$OWNER_CHECK_DIR")
    if [ "$BREW_OWNER" != "$SERVICE_USER" ]; then
        log "[ERROR] Homebrew n'appartient pas à $SERVICE_USER (owner: $BREW_OWNER)"
        log "Re-déploie install_homebrew.sh pour corriger."
        exit 1
    fi
fi
log "Homebrew : $BREW_BIN (owner: $SERVICE_USER) ✓"

# -------------------------------------------------------------------------
# 4. brew update
# -------------------------------------------------------------------------
log "brew update..."
sudo -u "$SERVICE_USER" -H "$BREW_BIN" update >> "$LOG" 2>&1 || {
    log "[WARN] brew update a échoué (non-bloquant)"
}

# -------------------------------------------------------------------------
# 5. Install ou upgrade
# -------------------------------------------------------------------------
if sudo -u "$SERVICE_USER" -H "$BREW_BIN" list --cask "$CASK_NAME" >/dev/null 2>&1; then
    log "$CASK_NAME déjà installé, tentative d'upgrade..."
    sudo -u "$SERVICE_USER" -H "$BREW_BIN" upgrade --cask "$CASK_NAME" >> "$LOG" 2>&1 || true
else
    log "Installation du cask $CASK_NAME (peut prendre 1-10 min)..."
    if ! sudo -u "$SERVICE_USER" -H "$BREW_BIN" install --cask "$CASK_NAME" >> "$LOG" 2>&1; then
        log "[ERROR] brew install --cask $CASK_NAME a échoué"
        log "Détails dans le log ci-dessus."
        exit 1
    fi
fi

# -------------------------------------------------------------------------
# 6. Vérification post-install
# -------------------------------------------------------------------------
if [ -n "$APP_FILENAME" ]; then
    APP_PATH="/Applications/$APP_FILENAME"
    if [ -e "$APP_PATH" ]; then
        log "App installée à : $APP_PATH"
    else
        log "[WARN] $APP_PATH non trouvé après install"
    fi
fi

log "=== Cask install successful : $CASK_NAME ==="
exit 0
