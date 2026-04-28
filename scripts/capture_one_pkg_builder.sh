#!/bin/bash
# Build le PKG Capture One avec la dernière version embarquée.
# Version portable (pas de paths hardcodés) destinée à être versionnée dans le
# repo et exécutée par le workflow GitHub Actions self-hosted runner.
#
# Cette version diffère de la version locale uniquement par :
#   - Les paths sont calculés relativement au repo (ou via env var)
#   - Pas de pbcopy (inutile en CI)
#   - Pas de récap final orienté "GitHub Desktop" (inutile en CI)
#   - Sortie GitHub Actions compatible ($GITHUB_OUTPUT)
#
# Usage local :
#   ./scripts/capture_one_pkg_builder.sh
# Usage CI (déjà configuré dans le workflow) :
#   FLEET_GITOPS_REPO_PATH=/path/to/checkout ./scripts/capture_one_pkg_builder.sh

set -euo pipefail

# --- Couleurs (auto-désactivées en CI sans tty) ---
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''; BLUE=''; YELLOW=''; RED=''; NC=''
fi

# --- Détection du répertoire du repo ---
# Priorité 1 : variable d'env (utilisée par CI)
# Priorité 2 : remonter depuis le script (le script est dans <repo>/scripts/)
if [ -n "${FLEET_GITOPS_REPO_PATH:-}" ]; then
    REPO_ROOT="$FLEET_GITOPS_REPO_PATH"
else
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
fi

if [ ! -d "$REPO_ROOT/lib/unassigned" ]; then
    echo -e "${RED}[ERROR] Le répertoire $REPO_ROOT/lib/unassigned n'existe pas.${NC}"
    echo "Définis FLEET_GITOPS_REPO_PATH ou place ce script dans <repo>/scripts/"
    exit 1
fi

# --- Configuration ---
XML_URL="https://www.captureone.com/update/capture-one-mac.xml"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/capture_one.pkg"
REPO="souari1974/fleet-gitops"
YAML_FILE="$REPO_ROOT/lib/unassigned/software/capture_one.yml"

# URL fixe (ne change jamais entre les versions)
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/capture_one.pkg"

# Identifiant Apple Developer Team de Capture One A/S
EXPECTED_TEAM_ID="5WTDB5F65L"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Capture One — PKG Builder (CI/local)   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Fetch version ---
echo -e "${BLUE}[1/4] Fetching latest Capture One version...${NC}"

XML_CONTENT=$(curl -sSL --fail --max-time 30 "$XML_URL") || {
    echo -e "${RED}[ERROR] Failed to fetch manifest${NC}"
    exit 1
}

LATEST_VERSION=$(echo "$XML_CONTENT" | grep -A 5 "<item>" | grep "<title>" | head -n 1 | sed -E 's/.*<title>(.*)<\/title>.*/\1/')
DOWNLOAD_URL=$(echo "$XML_CONTENT" | grep -oE 'url="https://[^"]+\.dmg"' | head -n 1 | cut -d'"' -f2)

if [ -z "$LATEST_VERSION" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${RED}[ERROR] Unable to parse version or URL${NC}"
    exit 1
fi

MAJOR_VERSION=$(echo "$LATEST_VERSION" | cut -d'.' -f1)
PKG_IDENTIFIER="com.captureone.captureone${MAJOR_VERSION}"

echo -e "${GREEN}  ✓ Version:    $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ Major:      $MAJOR_VERSION${NC}"
echo -e "${GREEN}  ✓ Bundle ID:  $PKG_IDENTIFIER${NC}"
echo -e "${GREEN}  ✓ DMG URL:    $DOWNLOAD_URL${NC}"
echo ""

# --- Étape 2 : Prepare postinstall ---
echo -e "${BLUE}[2/4] Preparing postinstall script...${NC}"

mkdir -p "$SCRIPTS_DIR"

cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# Capture One installer — built on $(date '+%Y-%m-%d %H:%M:%S')
# Target version: $LATEST_VERSION
# Expected TeamIdentifier: $EXPECTED_TEAM_ID (Capture One A/S)

set -euo pipefail

TARGET_VERSION="$LATEST_VERSION"
DOWNLOAD_URL="$DOWNLOAD_URL"
EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID"
APP_PATH="/Applications/Capture One.app"
TEMP_DIR=\$(mktemp -d)
DMG_PATH="\$TEMP_DIR/CaptureOne.dmg"
MOUNT_POINT="\$TEMP_DIR/CaptureOneMount"
LOG="/var/log/capture_one_install.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"
}

cleanup() {
    hdiutil detach "\$MOUNT_POINT" -force -quiet 2>/dev/null || true
    rm -rf "\$TEMP_DIR"
}
trap cleanup EXIT

log "=== Capture One install/update started ==="
log "Target version: \$TARGET_VERSION"
log "Expected TeamID: \$EXPECTED_TEAM_ID"

if [ -d "\$APP_PATH" ]; then
    INSTALLED_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: \$INSTALLED_VERSION"
    if [ "\$INSTALLED_VERSION" = "\$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from \$INSTALLED_VERSION to \$TARGET_VERSION..."
else
    log "Capture One not installed, performing fresh install..."
fi

log "Downloading from \$DOWNLOAD_URL..."
curl -sSL --fail --max-time 1800 "\$DOWNLOAD_URL" -o "\$DMG_PATH" || {
    log "[ERROR] Download failed"
    exit 1
}

DMG_SIZE=\$(du -h "\$DMG_PATH" | awk '{print \$1}')
log "DMG downloaded: \$DMG_SIZE"

log "Mounting DMG..."
mkdir -p "\$MOUNT_POINT"
hdiutil attach "\$DMG_PATH" -mountpoint "\$MOUNT_POINT" -nobrowse -quiet || {
    log "[ERROR] Failed to mount DMG"
    exit 1
}

SOURCE_APP="\$MOUNT_POINT/Capture One.app"
if [ ! -d "\$SOURCE_APP" ]; then
    log "[ERROR] Capture One.app not found in DMG at \$SOURCE_APP"
    log "[ERROR] DMG content:"
    ls -la "\$MOUNT_POINT" | tee -a "\$LOG"
    exit 1
fi

log "Verifying app signature integrity..."
codesign --verify --deep --strict "\$SOURCE_APP" 2>&1 | tee -a "\$LOG" || {
    log "[ERROR] App signature invalid"
    exit 1
}

APP_AUTHORITY=\$(codesign -dvv "\$SOURCE_APP" 2>&1 | grep "Authority=" | head -n 1 || echo "")
APP_TEAM_ID=\$(codesign -dvv "\$SOURCE_APP" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
log "App signed by:   \$APP_AUTHORITY"
log "Team Identifier: \$APP_TEAM_ID"

if [ "\$APP_TEAM_ID" != "\$EXPECTED_TEAM_ID" ]; then
    log "[ERROR] Unexpected Team Identifier"
    log "[ERROR]   Expected: \$EXPECTED_TEAM_ID"
    log "[ERROR]   Got:      \$APP_TEAM_ID"
    exit 1
fi
log "TeamID match: OK (\$APP_TEAM_ID)"

log "Verifying Apple notarization..."
NOTARIZE_RESULT=\$(spctl -a -vv -t install "\$SOURCE_APP" 2>&1 || true)
echo "\$NOTARIZE_RESULT" | tee -a "\$LOG"
if ! echo "\$NOTARIZE_RESULT" | grep -q "accepted"; then
    log "[ERROR] App is not notarized by Apple — aborting"
    exit 1
fi
log "Notarization: OK"

if pgrep -x "Capture One" > /dev/null; then
    log "Capture One is running — asking it to quit gracefully..."
    osascript -e 'tell application "Capture One" to quit' 2>/dev/null || true
    
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if ! pgrep -x "Capture One" > /dev/null; then
            log "Capture One quit cleanly after \$((i*2))s"
            break
        fi
        sleep 2
    done
    
    if pgrep -x "Capture One" > /dev/null; then
        log "[WARN] Capture One did not quit gracefully — force killing"
        pkill -9 -x "Capture One" 2>/dev/null || true
        sleep 2
    fi
fi

log "Installing..."
if [ -d "\$APP_PATH" ]; then
    rm -rf "\$APP_PATH"
fi

cp -R "\$SOURCE_APP" "/Applications/" || {
    log "[ERROR] Copy failed"
    exit 1
}

if [ ! -d "\$APP_PATH" ]; then
    log "[ERROR] App not found after copy"
    exit 1
fi

NEW_INSTALLED=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "FAILED")
if [ "\$NEW_INSTALLED" != "\$TARGET_VERSION" ]; then
    log "[ERROR] Version mismatch after install"
    log "[ERROR]   Expected: \$TARGET_VERSION"
    log "[ERROR]   Got:      \$NEW_INSTALLED"
    exit 1
fi

log "Installation verified: \$NEW_INSTALLED"
log "=== Capture One install/update successful ==="
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ postinstall embedded with version $LATEST_VERSION${NC}"
echo ""

# --- Étape 3 : Build PKG ---
echo -e "${BLUE}[3/4] Building PKG...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$LATEST_VERSION" \
    --nopayload \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Capture One $MAJOR_VERSION</title>
    <pkg-ref id="$PKG_IDENTIFIER"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_IDENTIFIER" visible="false">
        <pkg-ref id="$PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$PKG_IDENTIFIER" version="$LATEST_VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution "$DIST_XML" \
    --package-path "$BUILD_DIR" \
    "$OUTPUT_PKG" > /dev/null

if [ ! -f "$OUTPUT_PKG" ]; then
    echo -e "${RED}[ERROR] PKG build failed${NC}"
    exit 1
fi

PKG_SIZE=$(du -h "$OUTPUT_PKG" | awk '{print $1}')
PKG_HASH=$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')

if [ -z "$PKG_HASH" ] || [ ${#PKG_HASH} -ne 64 ]; then
    echo -e "${RED}[ERROR] Invalid SHA-256 computed: '$PKG_HASH'${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 4 : Update YAML ---
echo -e "${BLUE}[4/4] Updating capture_one.yml...${NC}"

mkdir -p "$(dirname "$YAML_FILE")"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icon/capture_one.png
  install_script:
    path: ./install_capture_one.sh
  uninstall_script:
    path: ./uninstall_capture_one.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"
echo ""

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$LATEST_VERSION"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

# --- Récap ---
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  Version    : $LATEST_VERSION"
echo "  Bundle ID  : $PKG_IDENTIFIER"
echo "  PKG        : $OUTPUT_PKG"
echo "  Size       : $PKG_SIZE"
echo "  SHA256     : $PKG_HASH"
echo "  TeamID     : $EXPECTED_TEAM_ID"
echo ""
