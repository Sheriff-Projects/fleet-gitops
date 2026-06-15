#!/bin/bash
# Script d'installation Fleet — Capture One
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/capture_one_install.log"
APP_PATH="/Applications/Capture One.app"
EXPECTED_TEAM_ID="5WTDB5F65L"
EXPECTED_BUNDLE_ID="com.captureone.captureone16"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install Capture One ==="



XML_TMP=$(mktemp)
curl -sSL --fail "https://www.captureone.com/update/capture-one-mac.xml" -o "$XML_TMP"
DOWNLOAD_URL=$(python3 - "$XML_TMP" "item/enclosure/@url" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
fn, upath = sys.argv[1], sys.argv[2]
root = ET.parse(fn).getroot()
def ln(t): return t.split('}')[-1]
attr = None
if '/@' in upath:
    upath, attr = upath.rsplit('/@', 1)
nodes = [root]
for part in [p.split(':')[-1] for p in upath.split('/') if p]:
    nodes = [c for n in nodes for c in n.iter() if c is not n and ln(c.tag) == part]
    if not nodes:
        print(''); raise SystemExit
el = nodes[0]
print(next((v for k, v in el.attrib.items() if ln(k) == attr), '') if attr else (el.text or '').strip())
PYEOF
)
rm -f "$XML_TMP"

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }




MNT="$TEMP_DIR/mnt"; mkdir -p "$MNT"
hdiutil attach "$ART" -mountpoint "$MNT" -nobrowse -quiet || { log "[ERROR] montage DMG échoué"; exit 1; }
SRC=$(find "$MNT" -maxdepth 2 -name "*.app" | head -n 1)

[ -n "$SRC" ] && [ -d "$SRC" ] || { log "[ERROR] .app introuvable dans l'artefact"; exit 1; }

codesign --verify --deep --strict "$SRC" 2>&1 | tee -a "$LOG" || { log "[ERROR] codesign invalide"; exit 1; }


TID=$(codesign -dvv "$SRC" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
[ "$TID" = "$EXPECTED_TEAM_ID" ] || { log "[ERROR] TeamID inattendu : $TID (attendu $EXPECTED_TEAM_ID)"; exit 1; }
log "TeamID OK ($TID)"


spctl -a -vv -t install "$SRC" 2>&1 | tee -a "$LOG" || log "[WARN] notarisation non confirmée"


osascript -e 'quit app "Capture One"' 2>/dev/null || pkill -f "Capture One" 2>/dev/null || true

[ -d "$APP_PATH" ] && rm -rf "$APP_PATH"
ditto "$SRC" "$APP_PATH"
log "App copiée dans $APP_PATH"




log "=== Install terminée ==="
exit 0

