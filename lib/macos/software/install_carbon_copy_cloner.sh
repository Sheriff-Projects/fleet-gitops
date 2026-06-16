#!/bin/bash
# Script d'installation Fleet — Carbon Copy Cloner
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/carbon_copy_cloner_install.log"
APP_PATH="/Applications/Carbon Copy Cloner.app"
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install Carbon Copy Cloner ==="



DOWNLOAD_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "https://api.bombich.com/download/ccc?v=ccc7")

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }




EXDIR="$TEMP_DIR/extract"; mkdir -p "$EXDIR"
ditto -x -k "$ART" "$EXDIR" 2>/dev/null || unzip -q "$ART" -d "$EXDIR"
SRC=$(find "$EXDIR" -maxdepth 2 -name "*.app" | head -n 1)

[ -n "$SRC" ] && [ -d "$SRC" ] || { log "[ERROR] .app introuvable dans l'artefact"; exit 1; }

codesign --verify --deep --strict "$SRC" 2>&1 | tee -a "$LOG" || { log "[ERROR] codesign invalide"; exit 1; }


TID=$(codesign -dvv "$SRC" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
[ "$TID" = "$EXPECTED_TEAM_ID" ] || { log "[ERROR] TeamID inattendu : $TID (attendu $EXPECTED_TEAM_ID)"; exit 1; }
log "TeamID OK ($TID)"


spctl -a -vv -t install "$SRC" 2>&1 | tee -a "$LOG" || log "[WARN] notarisation non confirmée"


osascript -e 'quit app "Carbon Copy Cloner"' 2>/dev/null || pkill -f "Carbon Copy Cloner" 2>/dev/null || true

[ -d "$APP_PATH" ] && rm -rf "$APP_PATH"
ditto "$SRC" "$APP_PATH"
log "App copiée dans $APP_PATH"




log "=== Install terminée ==="
exit 0

