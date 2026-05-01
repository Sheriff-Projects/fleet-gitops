#!/bin/bash
# Build le PKG Carbon Copy Cloner avec l'app embarquée (payload réel).
# Le PKG est versionné dans Git, URL fixe via raw.githubusercontent.com.
#
# v2 (2026-05-01) — Refactorisation Piste B (PKG embarqué)
#   - Plus de stub : le PKG contient maintenant Carbon Copy Cloner.app dans son payload
#   - URL Bombich corrigée : api.bombich.com/download/ccc?v=ccc7 (était scdn1.secure.raxcdn.com)
#   - Détection de version via redirect URL (technique de Sheriff) pour gagner en efficacité
#   - --root au lieu de --nopayload : génère un vrai receipt pkg → bouton Uninstall en self-service
#   - Plus de download dans le postinstall : install fonctionne sans réseau
#   - Postinstall réduit à : copie de l'app + désactivation Sparkle
#
# Spécificités CCC :
#   - Source : ZIP (pas DMG comme Capture One)
#   - URL : api.bombich.com/download/ccc?v=ccc7
#   - PKG résultant : ~27 MB (contient l'app)
#   - Désactivation auto-update Sparkle natif après install
#
# Usage local :
#   ./scripts/carbon_copy_cloner_pkg_builder.sh
# Usage CI :
#   FLEET_GITOPS_REPO_PATH=/path/to/checkout ./scripts/carbon_copy_cloner_pkg_builder.sh

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
DOWNLOAD_URL="https://api.bombich.com/download/ccc?v=ccc7"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/carbon_copy_cloner.pkg"
REPO="souari1974/fleet-gitops"
YAML_FILE="$REPO_ROOT/lib/unassigned/software/carbon_copy_cloner.yml"

# URL fixe (ne change jamais entre les versions)
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/carbon_copy_cloner.pkg"

# Identifiants Bombich (à vérifier via : codesign -dvv ".../Carbon Copy Cloner.app")
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"

PKG_IDENTIFIER="com.bombich.ccc.pkg"

BUILD_DIR=$(mktemp -d)
WORK_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
PAYLOAD_ROOT="$BUILD_DIR/payload"  # Racine du payload PKG (contiendra l'app)

trap 'rm -rf "$BUILD_DIR" "$WORK_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Carbon Copy Cloner — PKG Builder v2     ║${NC}"
echo -e "${BLUE}║  (embedded payload, with receipt)        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Détection de version via filename (technique Sheriff) ---
# On suit les redirections Bombich SANS télécharger (-o /dev/null) pour
# récupérer le filename effectif, qui contient la version + build number.
# Exemple : ccc-7.1.5.8335.zip
echo -e "${BLUE}[1/5] Detecting CCC version via Bombich redirect...${NC}"

EFFECTIVE_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "$DOWNLOAD_URL" || echo "")
if [ -z "$EFFECTIVE_URL" ] || [ "$EFFECTIVE_URL" = "$DOWNLOAD_URL" ]; then
    echo -e "${RED}[ERROR] No redirect detected — Bombich endpoint may have changed${NC}"
    echo -e "${YELLOW}  Original URL: $DOWNLOAD_URL${NC}"
    echo -e "${YELLOW}  Effective URL: $EFFECTIVE_URL${NC}"
    exit 1
fi

ZIP_FILENAME=$(echo "$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
echo -e "${GREEN}  ✓ Effective URL: $EFFECTIVE_URL${NC}"
echo -e "${GREEN}  ✓ ZIP filename:  $ZIP_FILENAME${NC}"

# Extraction de la version depuis le filename : ccc-7.1.5.8335.zip → 7.1.5.8335
FILENAME_VERSION=$(echo "$ZIP_FILENAME" | sed -E 's/^ccc-([0-9.]+)\.zip$/\1/')
if [ "$FILENAME_VERSION" = "$ZIP_FILENAME" ]; then
    # Le sed n'a pas matché, format inattendu
    echo -e "${YELLOW}[WARN] Filename format unexpected: $ZIP_FILENAME${NC}"
    echo -e "${YELLOW}        Will use Info.plist version after extraction${NC}"
    FILENAME_VERSION=""
else
    echo -e "${GREEN}  ✓ Filename version: $FILENAME_VERSION${NC}"
fi

# --- Étape 2 : Téléchargement et extraction ---
echo ""
echo -e "${BLUE}[2/5] Downloading and extracting CCC...${NC}"

ZIP_PATH="$WORK_DIR/ccc.zip"
EXTRACT_DIR="$WORK_DIR/extracted"

curl -sSL --fail --max-time 600 "$DOWNLOAD_URL" -o "$ZIP_PATH" || {
    echo -e "${RED}[ERROR] Failed to download CCC zip${NC}"
    echo -e "${RED}  URL: $DOWNLOAD_URL${NC}"
    exit 1
}

ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
ZIP_SIZE_BYTES=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH" 2>/dev/null || echo 0)

# Sanity check : un ZIP CCC fait ~27 MB. Si on reçoit moins de 1 MB, c'est probablement
# une page HTML ou une erreur déguisée en succès.
if [ "$ZIP_SIZE_BYTES" -lt 1048576 ]; then
    echo -e "${RED}[ERROR] ZIP suspiciously small: $ZIP_SIZE${NC}"
    echo -e "${RED}        Likely received HTML error page instead of binary${NC}"
    file "$ZIP_PATH"
    exit 1
fi

echo -e "${GREEN}  ✓ ZIP downloaded: $ZIP_SIZE${NC}"

mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR" || {
    echo -e "${RED}[ERROR] Failed to unzip CCC archive${NC}"
    file "$ZIP_PATH"
    exit 1
}

CCC_APP="$EXTRACT_DIR/Carbon Copy Cloner.app"
if [ ! -d "$CCC_APP" ]; then
    echo -e "${RED}[ERROR] Carbon Copy Cloner.app not found in zip${NC}"
    echo "Contents of zip:"
    ls -la "$EXTRACT_DIR"
    exit 1
fi

# --- Lecture des métadonnées de l'app ---
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CCC_APP/Contents/Info.plist" 2>/dev/null || echo "")
APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CCC_APP/Contents/Info.plist" 2>/dev/null || echo "")

if [ -z "$APP_VERSION" ]; then
    echo -e "${RED}[ERROR] Unable to read CCC version from Info.plist${NC}"
    exit 1
fi

if [ "$APP_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo -e "${RED}[ERROR] Unexpected bundle ID: $APP_BUNDLE_ID (expected $EXPECTED_BUNDLE_ID)${NC}"
    exit 1
fi

# Choix de la version finale : priorité au filename (qui inclut le build number)
# car deux releases avec même CFBundleShortVersionString peuvent avoir des build différents.
# Si filename non parseable, fallback sur l'Info.plist.
if [ -n "$FILENAME_VERSION" ]; then
    PKG_VERSION="$FILENAME_VERSION"
else
    PKG_VERSION="$APP_VERSION"
fi

echo -e "${GREEN}  ✓ App version (Info.plist): $APP_VERSION${NC}"
echo -e "${GREEN}  ✓ PKG version (utilisée):   $PKG_VERSION${NC}"
echo -e "${GREEN}  ✓ Bundle ID:                $APP_BUNDLE_ID${NC}"

# --- Étape 3 : Vérification de signature et notarisation ---
echo ""
echo -e "${BLUE}[3/5] Verifying signature and notarization...${NC}"

# Intégrité de la signature
codesign --verify --deep --strict "$CCC_APP" 2>&1 || {
    echo -e "${RED}[ERROR] App signature invalid${NC}"
    exit 1
}

# TeamID Bombich
APP_TEAM_ID=$(codesign -dvv "$CCC_APP" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
if [ "$APP_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
    echo -e "${RED}[ERROR] Unexpected TeamID: $APP_TEAM_ID (expected $EXPECTED_TEAM_ID)${NC}"
    echo -e "${YELLOW}If Bombich genuinely changed their TeamID, update EXPECTED_TEAM_ID in this script.${NC}"
    exit 1
fi

# Notarisation Apple (verifie aussi que Gatekeeper accepte)
NOTARIZE_RESULT=$(spctl -a -vv -t install "$CCC_APP" 2>&1 || true)
if ! echo "$NOTARIZE_RESULT" | grep -q "accepted"; then
    echo -e "${RED}[ERROR] App is not notarized by Apple${NC}"
    echo "$NOTARIZE_RESULT"
    exit 1
fi

echo -e "${GREEN}  ✓ Signature integrity: OK${NC}"
echo -e "${GREEN}  ✓ TeamID match:        OK ($APP_TEAM_ID)${NC}"
echo -e "${GREEN}  ✓ Notarization:        OK${NC}"

# --- Étape 4 : Préparation du payload et du postinstall ---
echo ""
echo -e "${BLUE}[4/5] Preparing PKG payload and postinstall...${NC}"

# Le payload du PKG contient l'app à installer dans /Applications
mkdir -p "$PAYLOAD_ROOT/Applications"
cp -R "$CCC_APP" "$PAYLOAD_ROOT/Applications/" || {
    echo -e "${RED}[ERROR] Failed to copy app to payload${NC}"
    exit 1
}

# Postinstall minimaliste : juste désactiver Sparkle.
# Plus besoin de download ni de check signature (déjà fait au build, l'app est déjà copiée par installer).
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << 'EOF'
#!/bin/bash
# Postinstall Carbon Copy Cloner
# - Désactive l'auto-update Sparkle (Fleet pilote les updates, pas CCC)
# - L'app a déjà été copiée par macOS installer dans /Applications/

set -uo pipefail

LOG="/var/log/carbon_copy_cloner_install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Carbon Copy Cloner postinstall started ==="

# Vérification post-install (l'app doit être en place après le payload)
APP_PATH="/Applications/Carbon Copy Cloner.app"
if [ ! -d "$APP_PATH" ]; then
    log "[ERROR] App not found at $APP_PATH after payload install"
    exit 1
fi

INSTALLED_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
log "Installed version: $INSTALLED_VERSION"

# Désactivation Sparkle (system-wide via /Library/Preferences/)
log "Disabling Sparkle auto-update..."
defaults write /Library/Preferences/com.bombich.ccc SUEnableAutomaticChecks -bool false
defaults write /Library/Preferences/com.bombich.ccc SUAutomaticallyUpdate -bool false
log "Sparkle disabled"

log "=== Carbon Copy Cloner postinstall successful ==="
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"

# Taille du payload pour info
PAYLOAD_SIZE=$(du -sh "$PAYLOAD_ROOT" | awk '{print $1}')
echo -e "${GREEN}  ✓ Payload prepared: $PAYLOAD_SIZE${NC}"
echo -e "${GREEN}  ✓ Postinstall configured (disable Sparkle)${NC}"

# --- Étape 5 : Build du PKG ---
echo ""
echo -e "${BLUE}[5/5] Building PKG...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

# pkgbuild --root → génère un receipt enregistré dans /var/db/receipts/
# C'est ce qui permet à Fleet de matcher le PKG avec l'app installée
# et donc d'afficher le bouton Uninstall en self-service.
COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$PKG_VERSION" \
    --root "$PAYLOAD_ROOT" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

# Distribution.xml pour le titre dans Installer.app
DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Carbon Copy Cloner</title>
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

# --- Update YAML ---
echo ""
echo -e "${BLUE}[6/6] Updating carbon_copy_cloner.yml...${NC}"

mkdir -p "$(dirname "$YAML_FILE")"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icon/ccc.png
  install_script:
    path: ./install_carbon_copy_cloner.sh
  uninstall_script:
    path: ./uninstall_carbon_copy_cloner.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$PKG_VERSION"
        echo "app_version=$APP_VERSION"
        echo "filename=$ZIP_FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

# --- Récap ---
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  ZIP filename : $ZIP_FILENAME"
echo "  App version  : $APP_VERSION"
echo "  PKG version  : $PKG_VERSION"
echo "  PKG path     : $OUTPUT_PKG"
echo "  PKG size     : $PKG_SIZE"
echo "  SHA256       : $PKG_HASH"
echo "  TeamID       : $EXPECTED_TEAM_ID"
echo ""