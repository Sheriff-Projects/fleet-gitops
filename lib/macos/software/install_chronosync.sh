#!/bin/bash
# Script d'installation Fleet — ChronoSync
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/chronosync_install.log"
APP_PATH="/Applications/ChronoSync.app"
EXPECTED_TEAM_ID="9U697UM7YX"
EXPECTED_BUNDLE_ID="com.econtechnologies.chronosync"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install ChronoSync ==="



DOWNLOAD_URL="https://downloads.econtechnologies.com/CS4_Download.dmg"

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }



MNT="$TEMP_DIR/mnt"; mkdir -p "$MNT"
hdiutil attach "$ART" -mountpoint "$MNT" -nobrowse -quiet

# Nom du pkg connu (cask Homebrew) — on le cible, avec repli sur une recherche générique.
PKG=$(find "$MNT" -maxdepth 2 -name "Install.pkg" | head -n 1)
[ -z "$PKG" ] && PKG=$(find "$MNT" -maxdepth 2 \( -name "*.pkg" -o -name "*.mpkg" \) | head -n 1)

[ -n "$PKG" ] || { log "[ERROR] aucun .pkg trouvé dans le DMG"; exit 1; }
log "Installation de $PKG..."
installer -pkg "$PKG" -target / | tee -a "$LOG"



log "=== Install terminée ==="
exit 0
