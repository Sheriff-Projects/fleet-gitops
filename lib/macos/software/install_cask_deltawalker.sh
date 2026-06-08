#!/bin/bash
# Install DeltaWalker via Homebrew Cask
# Build on 2026-06-09 01:35:58
# Cask       : deltawalker (v2.8.1)
# Bundle ID  : com.deltopia.DeltaWalker
#
# Logique 3 cas :
#   a) Pas installé selon brew → brew install --cask
#   b) Installé ET app présente → brew upgrade --cask (cas normal)
#   c) Installé selon brew MAIS app manquante (user l'a viré à la corbeille)
#      → brew reinstall --cask --force (resync l'état)

set -uo pipefail

SERVICE_USER="sp-installer"
CASK_NAME="deltawalker"
APP_FILENAME="DeltaWalker.app"

LOG="/var/log/cask_${CASK_NAME}_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

log "=== Cask install : $CASK_NAME (via $SERVICE_USER) ==="

cd /tmp || cd /

# Vérif sp-installer
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "[ERROR] Le compte $SERVICE_USER n'existe pas"
    exit 1
fi

# Arch + brew
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
BREW_BIN="$BREW_PREFIX/bin/brew"

if [ ! -x "$BREW_BIN" ]; then
    log "[ERROR] Homebrew absent à $BREW_BIN"
    exit 1
fi
log "Homebrew : $BREW_BIN"

# brew update (best effort)
log "brew update..."
sudo -u "$SERVICE_USER" -H "$BREW_BIN" update >> "$LOG" 2>&1 || {
    log "[WARN] brew update a échoué (non-bloquant)"
}

# -------------------------------------------------------------------------
# Détection : brew connaît-il ce cask comme installé ?
# -------------------------------------------------------------------------
BREW_THINKS_INSTALLED=0
if sudo -u "$SERVICE_USER" -H "$BREW_BIN" list --cask "$CASK_NAME" >/dev/null 2>&1; then
    BREW_THINKS_INSTALLED=1
fi

# -------------------------------------------------------------------------
# Détection : l'app physique est-elle dans /Applications/ ?
# -------------------------------------------------------------------------
APP_PRESENT=0
if [ -n "$APP_FILENAME" ] && [ -e "/Applications/$APP_FILENAME" ]; then
    APP_PRESENT=1
fi

log "État : brew_thinks_installed=$BREW_THINKS_INSTALLED, app_present=$APP_PRESENT"

# -------------------------------------------------------------------------
# 3 branches selon l'état
# -------------------------------------------------------------------------
if [ "$BREW_THINKS_INSTALLED" = "0" ]; then
    # Cas A : Pas installé → install propre
    log "Cas A : Installation propre du cask $CASK_NAME..."
    if ! sudo -u "$SERVICE_USER" -H "$BREW_BIN" install --cask "$CASK_NAME" >> "$LOG" 2>&1; then
        log "[ERROR] brew install --cask $CASK_NAME a échoué"
        exit 1
    fi
elif [ "$BREW_THINKS_INSTALLED" = "1" ] && [ "$APP_PRESENT" = "1" ]; then
    # Cas B : Tout OK → upgrade éventuel
    log "Cas B : Déjà installé et app présente, tentative d'upgrade..."
    sudo -u "$SERVICE_USER" -H "$BREW_BIN" upgrade --cask "$CASK_NAME" >> "$LOG" 2>&1 || true
else
    # Cas C : Brew pense que c'est installé mais l'app a disparu
    # → reinstall forcé pour resync
    log "Cas C : DÉSYNCHRONISÉ — brew connaît le cask mais l'app manque"
    log "Force reinstall --cask --force pour resync..."
    if ! sudo -u "$SERVICE_USER" -H "$BREW_BIN" reinstall --cask --force "$CASK_NAME" >> "$LOG" 2>&1; then
        log "[ERROR] reinstall a échoué, fallback : uninstall puis install"
        sudo -u "$SERVICE_USER" -H "$BREW_BIN" uninstall --cask --force "$CASK_NAME" >> "$LOG" 2>&1 || true
        if ! sudo -u "$SERVICE_USER" -H "$BREW_BIN" install --cask "$CASK_NAME" >> "$LOG" 2>&1; then
            log "[ERROR] Install après uninstall a aussi échoué"
            exit 1
        fi
    fi
fi

# -------------------------------------------------------------------------
# Vérification FINALE : l'app doit être présente, sinon on a vraiment échoué
# -------------------------------------------------------------------------
if [ -n "$APP_FILENAME" ]; then
    APP_PATH="/Applications/$APP_FILENAME"
    if [ -e "$APP_PATH" ]; then
        log "✓ App installée à : $APP_PATH"
    else
        log "[ERROR] $APP_PATH manquant même après install/reinstall"
        log "Vérifie manuellement avec : ls /Applications | grep -i $CASK_NAME"
        exit 1
    fi
fi

log "=== Cask install successful : $CASK_NAME ==="
exit 0
