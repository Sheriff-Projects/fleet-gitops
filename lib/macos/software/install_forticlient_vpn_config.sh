#!/bin/bash
# Install script FortiClient VPN config — wrapper minimal autour de installer(8).
# Le PKG contient le vpn.plist dans son payload et un postinstall qui redémarre
# les agents FortiClient. Pas de logique métier ici.
#
# Built on 2026-05-24 21:39:18
# PKG version: 2026.05.24.213918

set -uo pipefail

PKG_URL="https://github.com/Sheriff-Projects/fleet-gitops/releases/download/forticlient_vpn_config/forticlient_vpn_config.pkg"
TEMP_DIR=$(mktemp -d)
PKG_PATH="$TEMP_DIR/forticlient_vpn_config.pkg"
LOG="/var/log/forticlient_vpn_config_install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

log "=== FortiClient VPN config install started ==="

# Vérification préalable : FortiClient doit être installé pour que ça serve
if [ ! -d "/Applications/FortiClient.app" ]; then
    log "[WARN] FortiClient.app non installé — installe FortiClient d'abord, puis cette config."
    log "       La config sera posée quand même, elle sera utilisée au prochain démarrage de FortiClient."
fi

# Téléchargement du PKG (petit, < 10 Ko)
log "Downloading PKG from $PKG_URL..."
if ! curl -sSL --fail --max-time 60 "$PKG_URL" -o "$PKG_PATH"; then
    log "[ERROR] Download failed"
    exit 1
fi

PKG_DL_SIZE=$(du -h "$PKG_PATH" | awk '{print $1}')
log "Downloaded: $PKG_DL_SIZE"

# Installation (le postinstall du PKG fait le restart des agents)
log "Running installer -pkg..."
if ! installer -pkg "$PKG_PATH" -target / >> "$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

log "=== FortiClient VPN config install successful ==="
exit 0
