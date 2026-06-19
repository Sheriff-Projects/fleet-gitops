#!/bin/bash
# Script d'installation Fleet — desktoppr
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/desktoppr_install.log"
APP_PATH="usr/local/bin/desktoppr"
EXPECTED_TEAM_ID="JME5BW3F3R"
EXPECTED_BUNDLE_ID="com.scriptingosx.desktoppr"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install desktoppr ==="



DOWNLOAD_URL="https://github.com/scriptingosx/desktoppr/releases/download/v0.5/desktoppr-0.5-218.pkg"  # curl -sSL suivra les redirections au téléchargement

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }



log "Installation du PKG..."
installer -pkg "$ART" -target / | tee -a "$LOG"



log "=== Install terminée ==="
exit 0

