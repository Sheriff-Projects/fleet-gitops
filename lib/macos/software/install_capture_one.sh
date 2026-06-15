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





log "=== Install terminée ==="
exit 0

