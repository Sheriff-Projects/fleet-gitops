#!/bin/bash
# Build le PKG Wacom Tablet avec la dernière version embarquée.
# Pattern aligné sur capture_one_pkg_builder.sh et carbon_copy_cloner_pkg_builder.sh.
#
# Différence majeure : le DMG Wacom contient un .pkg (pas une .app à copier).
# Le postinstall fait donc `installer -pkg` au lieu de `cp -R`.
#
# Usage local :
#   ./scripts/wacom_tablet_pkg_builder.sh
# Usage CI :
#   FLEET_GITOPS_REPO_PATH=/path/to/checkout ./scripts/wacom_tablet_pkg_builder.sh



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
XML_URL="https://link.wacom.com/wdc/update.xml"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/wacom_tablet.pkg"
REPO="souari1974/fleet-gitops"
YAML_FILE="$REPO_ROOT/lib/unassigned/software/wacom_tablet.yml"

# URL fixe (ne change jamais entre les versions)
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/wacom_tablet.pkg"

# Identifiants Wacom
# ⚠️ Vérifie le TeamID au premier run : le postinstall log toujours le TeamID
#    effectif extrait du PKG embarqué dans le DMG. Si différent, mets à jour ici.
EXPECTED_TEAM_ID="EG27766DY7"

# Le PKG identifier doit matcher le bundle_id de l'app principale Wacom Center
# pour permettre à Fleet de faire le matching dans la Library.
# Bundle ID de "Wacom Center.app" = com.wacom.WacomCenter
PKG_IDENTIFIER="com.wacom.WacomCenter"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Wacom Tablet — PKG Builder (CI/local)  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Fetch version depuis le XML Wacom ---
echo -e "${BLUE}[1/4] Fetching latest Wacom Tablet version...${NC}"

XML_CONTENT=$(curl -s "$XML_URL")

MAC_SECTION=$(echo "$XML_CONTENT" | perl -0777 -ne 'print $1 if /<mac type="map">(.*?)<\/mac>/s')



FILENAME=$(echo "$MAC_SECTION" | perl -ne 'if (/<file type="string">(.*?.dmg)<\/file>/) { print $1; exit }')
URL_BASE=$(echo "$MAC_SECTION" | perl -0777 -ne 'if (/<file type="string">'"$FILENAME"'<\/file>\s*<url type="string">(.*?)<\/url>/s) { print $1; exit }')
DOWNLOAD_URL="${URL_BASE}${FILENAME}"

if [ -z "$FILENAME" ] || [ -z "$URL_BASE" ]; then
    echo -e "${RED}[ERROR] Impossible d'extraire filename ou URL${NC}"
    exit 1
fi

# Extraction de la version depuis le filename
# Format typique : WacomTablet_6.4.6-3.dmg → 6.4.6-3
# On essaie plusieurs patterns au cas où
LATEST_VERSION=$(echo "$FILENAME" | sed -nE 's/^[A-Za-z_]+_([0-9.]+(-[0-9]+)?)\.dmg$/\1/p')

if [ -z "$LATEST_VERSION" ]; then
    # Fallback : extraire tous les chiffres et points dans le filename
    LATEST_VERSION=$(echo "$FILENAME" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?).*/\1/p')
fi

if [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}[ERROR] Impossible de parser la version depuis '$FILENAME'${NC}"
    echo -e "${YELLOW}  Tu peux ajuster le regex dans la section [1/4] du builder${NC}"
    exit 1
fi

# Pour Fleet, on garde une version "propre" (sans le suffixe -X de build).
# CFBundleShortVersionString de Wacom Center est généralement au format X.Y.Z.
PKG_VERSION=$(echo "$LATEST_VERSION" | sed 's/-.*//')

echo -e "${GREEN}  ✓ DMG filename: $FILENAME${NC}"
echo -e "${GREEN}  ✓ Full URL:     $DOWNLOAD_URL${NC}"
echo -e "${GREEN}  ✓ Version raw:  $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ PKG version:  $PKG_VERSION (utilisée pour le wrapper)${NC}"
echo ""

# --- Étape 2 : Préparer le postinstall ---
echo -e "${BLUE}[2/4] Preparing postinstall script...${NC}"

mkdir -p "$SCRIPTS_DIR"

# Échappement dans le heredoc :
#   $VAR    → expansé MAINTENANT (build time), valeur hardcodée dans le postinstall
#   \$VAR   → expansé À L'EXÉCUTION du postinstall (install time, sur le Mac client)
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# Wacom Tablet installer (postinstall) — built on $(date '+%Y-%m-%d %H:%M:%S')
# Target version: $PKG_VERSION (raw: $LATEST_VERSION)
# Expected TeamID: $EXPECTED_TEAM_ID
#
# Ce postinstall :
#   1. Télécharge le DMG Wacom
#   2. Le monte
#   3. Vérifie la signature + TeamID + notarisation du PKG embarqué
#   4. Lance \`installer -pkg\` sur le PKG embarqué
#   5. Démonte et nettoie

set -euo pipefail

TARGET_VERSION="$PKG_VERSION"
DOWNLOAD_URL="$DOWNLOAD_URL"
EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID"
APP_PATH="/Applications/Tablette Wacom/Wacom Center.app"
TEMP_DIR=\$(mktemp -d)
DMG_PATH="\$TEMP_DIR/WacomTablet.dmg"
MOUNT_POINT="\$TEMP_DIR/WacomTabletMount"
LOG="/var/log/wacom_tablet_install.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"
}

cleanup() {
    hdiutil detach "\$MOUNT_POINT" -force -quiet 2>/dev/null || true
    rm -rf "\$TEMP_DIR"
}
trap cleanup EXIT

log "=== Wacom Tablet install/update started ==="
log "Target version: \$TARGET_VERSION"
log "Expected TeamID: \$EXPECTED_TEAM_ID"

# --- Check version installée (via Wacom Center.app) ---
if [ -d "\$APP_PATH" ]; then
    INSTALLED_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: \$INSTALLED_VERSION"
    if [ "\$INSTALLED_VERSION" = "\$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from \$INSTALLED_VERSION to \$TARGET_VERSION..."
else
    log "Wacom Center not installed, performing fresh install..."
fi

# --- Téléchargement du DMG ---
log "Downloading from \$DOWNLOAD_URL..."
curl -sSL --fail --max-time 1800 "\$DOWNLOAD_URL" -o "\$DMG_PATH" || {
    log "[ERROR] Download failed"
    exit 1
}

DMG_SIZE=\$(du -h "\$DMG_PATH" | awk '{print \$1}')
DMG_BYTES=\$(stat -f%z "\$DMG_PATH" 2>/dev/null || stat -c%s "\$DMG_PATH" 2>/dev/null || echo 0)
log "DMG downloaded: \$DMG_SIZE"

# Sanity check : un DMG Wacom fait ~70-100 MB selon les versions.
# Si moins de 5 MB, c'est probablement une page d'erreur HTML.
if [ "\$DMG_BYTES" -lt 5242880 ]; then
    log "[ERROR] DMG suspiciously small (\$DMG_BYTES bytes) — likely HTML error page"
    log "[ERROR] Wacom URL may have changed — rebuild the PKG"
    exit 1
fi

# --- Montage du DMG ---
log "Mounting DMG..."
mkdir -p "\$MOUNT_POINT"
hdiutil attach "\$DMG_PATH" -mountpoint "\$MOUNT_POINT" -nobrowse -quiet || {
    log "[ERROR] Failed to mount DMG"
    exit 1
}

# --- Recherche du PKG dans le DMG ---
# Le nom du PKG peut varier entre les versions Wacom :
#   - Install Wacom Tablet.pkg
#   - Wacom Tablet.pkg
#   - Install Wacom Drivers.pkg
# On prend le premier .pkg trouvé dans le DMG.
SOURCE_PKG=\$(find "\$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -type f 2>/dev/null | head -n 1)

if [ -z "\$SOURCE_PKG" ] || [ ! -f "\$SOURCE_PKG" ]; then
    log "[ERROR] Aucun .pkg trouvé dans le DMG monté"
    log "[ERROR] Contenu du DMG :"
    ls -la "\$MOUNT_POINT" | tee -a "\$LOG"
    exit 1
fi
log "PKG embarqué trouvé : \$SOURCE_PKG"

# --- Vérification signature du PKG ---
log "Verifying package signature..."
PKG_CHECK=\$(pkgutil --check-signature "\$SOURCE_PKG" 2>&1 || true)
echo "\$PKG_CHECK" | tee -a "\$LOG"

if ! echo "\$PKG_CHECK" | grep -q "signed by a developer certificate issued by Apple"; then
    log "[ERROR] Le PKG n'est pas signé par un Developer ID Apple — abort"
    exit 1
fi

# Extraction du TeamID depuis la sortie de --check-signature
PKG_TEAM_ID=\$(echo "\$PKG_CHECK" | grep -oE '\([A-Z0-9]{10}\)' | head -n 1 | tr -d '()')
log "Package Team Identifier: \$PKG_TEAM_ID"

if [ -z "\$PKG_TEAM_ID" ]; then
    log "[ERROR] Impossible d'extraire le TeamID du PKG"
    exit 1
fi

if [ "\$PKG_TEAM_ID" != "\$EXPECTED_TEAM_ID" ]; then
    log "[ERROR] Unexpected Team Identifier"
    log "[ERROR]   Expected: \$EXPECTED_TEAM_ID"
    log "[ERROR]   Got:      \$PKG_TEAM_ID"
    exit 1
fi
log "TeamID match: OK (\$PKG_TEAM_ID)"

# --- Vérification notarisation Apple ---
log "Verifying Apple notarization..."
NOTARIZE_RESULT=\$(spctl -a -vv -t install "\$SOURCE_PKG" 2>&1 || true)
echo "\$NOTARIZE_RESULT" | tee -a "\$LOG"
if ! echo "\$NOTARIZE_RESULT" | grep -q "accepted"; then
    log "[ERROR] PKG is not notarized by Apple — aborting"
    exit 1
fi
log "Notarization: OK"

# --- Quit gracieux des apps Wacom si elles tournent ---
for app_name in "Wacom Center" "Wacom Tablet Utility" "WacomTabletDriver"; do
    if pgrep -x "\$app_name" > /dev/null; then
        log "\$app_name is running — asking it to quit gracefully..."
        osascript -e "tell application \"\$app_name\" to quit" 2>/dev/null || true
        sleep 2
        pkill -9 -x "\$app_name" 2>/dev/null || true
    fi
done

# --- Installation du PKG Wacom ---
log "Installing PKG..."
if ! installer -pkg "\$SOURCE_PKG" -target / >> "\$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- Vérification post-install ---
if [ -d "\$APP_PATH" ]; then
    NEW_INSTALLED=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: Wacom Center \$NEW_INSTALLED"
else
    log "[WARN] /Applications/Wacom Center.app not found after install — version mismatch possible"
fi

log "=== Wacom Tablet install/update successful ==="
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ postinstall embedded with version $PKG_VERSION${NC}"
echo -e "${GREEN}  ✓ Postinstall will: download → verify → installer -pkg → cleanup${NC}"
echo ""

# --- Étape 3 : Build PKG (stub) ---
echo -e "${BLUE}[3/4] Building PKG (stub)...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

# Dossier vide qui sert de racine de payload :
#   - PKG sans fichier à installer (~10 KB)
#   - mais macOS génère quand même un receipt pour la traçabilité
mkdir -p "$EMPTY_PAYLOAD_ROOT"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$PKG_VERSION" \
    --root "$EMPTY_PAYLOAD_ROOT" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

# Distribution.xml pour le titre dans Installer.app
DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Wacom Tablet Driver</title>
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
    <pkg-ref id="$PKG_IDENTIFIER" version="$PKG_VERSION" onConclusion="none">component.pkg</pkg-ref>
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
    echo -e "${RED}[ERROR] Invalid SHA-256 computed${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 4 : Update YAML ---
echo -e "${BLUE}[4/4] Updating wacom_tablet.yml...${NC}"

mkdir -p "$(dirname "$YAML_FILE")"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icon/wacom_tablet.png
  install_script:
    path: ./install_wacom_tablet.sh
  uninstall_script:
    path: ./uninstall_wacom_tablet.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"
echo ""

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$PKG_VERSION"
        echo "raw_version=$LATEST_VERSION"
        echo "filename=$FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

# --- Récap ---
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  DMG filename   : $FILENAME"
echo "  Raw version    : $LATEST_VERSION"
echo "  PKG version    : $PKG_VERSION"
echo "  PKG identifier : $PKG_IDENTIFIER (matche bundle_id de Wacom Center.app)"
echo "  PKG path       : $OUTPUT_PKG"
echo "  PKG size       : $PKG_SIZE"
echo "  SHA256         : $PKG_HASH"
echo "  Expected TeamID: $EXPECTED_TEAM_ID"
echo ""