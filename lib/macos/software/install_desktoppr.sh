#!/bin/bash
# Script d'installation Fleet — desktoppr
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/desktoppr_install.log"
APP_PATH=""

EXPECTED_BUNDLE_ID="com.scriptingosx.desktoppr"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install desktoppr ==="



REPO_SLUG=$(echo "https://github.com/scriptingosx/desktoppr" | perl -ne 'print $1 and exit if m{github\.com/([^/]+/[^/]+?)(?:\.git|/|$)}')
GH_JSON=$(curl -sSL --fail -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO_SLUG/releases/latest")
DOWNLOAD_URL=$(echo "$GH_JSON" | python3 -c "import json,sys;a=json.load(sys.stdin).get('assets',[]);u=[x['browser_download_url'] for x in a if x['browser_download_url'].endswith(('.dmg','.pkg','.zip'))];print(u[0] if u else '')")

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }



log "Installation du PKG..."
installer -pkg "$ART" -target / | tee -a "$LOG"



log "=== Install terminée ==="
exit 0

