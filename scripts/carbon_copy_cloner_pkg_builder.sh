#!/bin/bash
# Build le PKG stub Carbon Copy Cloner.
# Le PKG est versionné dans Git, URL fixe via raw.githubusercontent.com.
#


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

# Identifiants Bombich
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"

# IMPORTANT : Le PKG identifier DOIT correspondre exactement au bundle ID de l'app
# pour que Fleet fasse le matching et affiche le bouton Uninstall en self-service.
# Donc PAS "com.bombich.ccc.pkg" mais "com.bombich.ccc" (identique au bundle ID).
PKG_IDENTIFIER="com.bombich.ccc"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Carbon Copy Cloner — PKG Builder v4     ║${NC}"
echo -e "${BLUE}║  (stub, with Fleet-compatible matching)  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Détection de version via filename (technique Sheriff) ---
# On suit les redirections Bombich SANS télécharger (-o /dev/null) pour
# récupérer le filename effectif, qui contient la version + build number.
# Exemple : ccc-7.1.5.8335.zip
#
# Pour Fleet, on doit utiliser la version "utilisateur" (3 segments : 7.1.5)
# et NON la version "build" (4 segments : 7.1.5.8335). En effet :
#   - Fleet détecte la version installée via CFBundleShortVersionString
#     dans l'Info.plist de l'app, qui contient "7.1.5"
#   - Si on met 7.1.5.8335 dans le PKG, Fleet voit 7.1.5 < 7.1.5.8335
#     et propose "Update available" éternellement
echo -e "${BLUE}[1/4] Detecting CCC version via Bombich redirect...${NC}"

EFFECTIVE_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "$DOWNLOAD_URL" || echo "")
if [ -z "$EFFECTIVE_URL" ] || [ "$EFFECTIVE_URL" = "$DOWNLOAD_URL" ]; then
    echo -e "${RED}[ERROR] No redirect detected — Bombich endpoint may have changed${NC}"
    echo -e "${YELLOW}  Original URL:  $DOWNLOAD_URL${NC}"
    echo -e "${YELLOW}  Effective URL: $EFFECTIVE_URL${NC}"
    exit 1
fi

ZIP_FILENAME=$(echo "$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
echo -e "${GREEN}  ✓ Effective URL: $EFFECTIVE_URL${NC}"
echo -e "${GREEN}  ✓ ZIP filename:  $ZIP_FILENAME${NC}"

# Extraction de la version "build" complète depuis le filename
BUILD_VERSION=$(echo "$ZIP_FILENAME" | sed -E 's/^ccc-([0-9.]+)\.zip$/\1/')
if [ "$BUILD_VERSION" = "$ZIP_FILENAME" ] || [ -z "$BUILD_VERSION" ]; then
    echo -e "${RED}[ERROR] Filename format unexpected: $ZIP_FILENAME${NC}"
    echo -e "${RED}        Expected pattern: ccc-VERSION.zip${NC}"
    exit 1
fi

# Conversion en version "utilisateur" : 7.1.5.8335 → 7.1.5 (3 premiers segments)
# C'est cette version qui matche celle dans Info.plist de l'app installée.
LATEST_VERSION=$(echo "$BUILD_VERSION" | awk -F. '{print $1"."$2"."$3}')

echo -e "${GREEN}  ✓ Build version: $BUILD_VERSION (filename)${NC}"
echo -e "${GREEN}  ✓ User version:  $LATEST_VERSION (used for PKG)${NC}"
echo ""

# --- Étape 2 : Préparer le postinstall ---
echo -e "${BLUE}[2/4] Preparing postinstall script...${NC}"

mkdir -p "$SCRIPTS_DIR"

# IMPORTANT sur l'échappement dans le heredoc :
#   $VAR    → expansé MAINTENANT (build time), valeur hardcodée dans le postinstall
#   \$VAR   → expansé À L'EXÉCUTION du postinstall (install time, sur le Mac client)
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# Carbon Copy Cloner installer (postinstall) — built on $(date '+%Y-%m-%d %H:%M:%S')
# Target version: $LATEST_VERSION (build $BUILD_VERSION)
# Expected TeamID: $EXPECTED_TEAM_ID (Bombich Software, Inc.)
#
# Ce postinstall :
#   1. Télécharge le ZIP CCC depuis Bombich
#   2. L'extrait
#   3. Vérifie signature + TeamID + notarisation
#   4. Quitte CCC s'il tourne
#   5. Copie l'app dans /Applications
#   6. Désactive Sparkle (Fleet pilote les updates)
#   7. Nettoie tous les fichiers temporaires (zip + extract dir)

set -euo pipefail

TARGET_VERSION="$LATEST_VERSION"
DOWNLOAD_URL="$DOWNLOAD_URL"
EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID"
EXPECTED_BUNDLE_ID="$EXPECTED_BUNDLE_ID"
APP_PATH="/Applications/Carbon Copy Cloner.app"
TEMP_DIR=\$(mktemp -d)
ZIP_PATH="\$TEMP_DIR/ccc.zip"
EXTRACT_DIR="\$TEMP_DIR/extracted"
LOG="/var/log/carbon_copy_cloner_install.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"
}

# Cleanup garanti même en cas d'erreur (efface zip + extract dir)
cleanup() {
    if [ -d "\$TEMP_DIR" ]; then
        rm -rf "\$TEMP_DIR"
        log "Cleaned up temporary files"
    fi
}
trap cleanup EXIT

log "=== Carbon Copy Cloner install/update started ==="
log "Target version: \$TARGET_VERSION"
log "Expected TeamID: \$EXPECTED_TEAM_ID"

# --- Check version installée ---
if [ -d "\$APP_PATH" ]; then
    INSTALLED_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: \$INSTALLED_VERSION"
    if [ "\$INSTALLED_VERSION" = "\$TARGET_VERSION" ]; then
        log "Already at target version. Just refreshing Sparkle settings."
        SKIP_INSTALL=1
    else
        SKIP_INSTALL=0
        log "Will upgrade from \$INSTALLED_VERSION to \$TARGET_VERSION..."
    fi
else
    SKIP_INSTALL=0
    log "Carbon Copy Cloner not installed, performing fresh install..."
fi

if [ "\$SKIP_INSTALL" = "0" ]; then
    # --- Téléchargement ZIP ---
    log "Downloading from \$DOWNLOAD_URL..."
    curl -sSL --fail --max-time 600 "\$DOWNLOAD_URL" -o "\$ZIP_PATH" || {
        log "[ERROR] Download failed"
        exit 1
    }
    
    ZIP_SIZE=\$(du -h "\$ZIP_PATH" | awk '{print \$1}')
    ZIP_BYTES=\$(stat -f%z "\$ZIP_PATH" 2>/dev/null || stat -c%s "\$ZIP_PATH" 2>/dev/null || echo 0)
    log "ZIP downloaded: \$ZIP_SIZE"
    
    # Sanity check : un ZIP CCC fait ~27 MB. Si on reçoit moins de 1 MB, c'est probablement
    # une page HTML d'erreur Bombich (cas survenu en dev quand l'URL avait changé).
    if [ "\$ZIP_BYTES" -lt 1048576 ]; then
        log "[ERROR] ZIP suspiciously small (\$ZIP_BYTES bytes) — likely HTML error page"
        log "[ERROR] Bombich URL may have changed — rebuild the PKG with updated URL"
        exit 1
    fi
    
    # --- Extraction ---
    log "Extracting ZIP..."
    mkdir -p "\$EXTRACT_DIR"
    unzip -q "\$ZIP_PATH" -d "\$EXTRACT_DIR" || {
        log "[ERROR] Failed to extract ZIP"
        exit 1
    }
    
    # On peut effacer le ZIP maintenant qu'on a extrait
    rm -f "\$ZIP_PATH"
    log "ZIP file removed (already extracted)"
    
    SOURCE_APP="\$EXTRACT_DIR/Carbon Copy Cloner.app"
    if [ ! -d "\$SOURCE_APP" ]; then
        log "[ERROR] Carbon Copy Cloner.app not found in ZIP"
        log "[ERROR] ZIP content:"
        ls -la "\$EXTRACT_DIR" | tee -a "\$LOG"
        exit 1
    fi
    
    # --- Vérification bundle ID ---
    APP_BUNDLE_ID=\$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "\$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "\$APP_BUNDLE_ID" != "\$EXPECTED_BUNDLE_ID" ]; then
        log "[ERROR] Unexpected bundle ID: \$APP_BUNDLE_ID (expected \$EXPECTED_BUNDLE_ID)"
        exit 1
    fi
    
    # --- Vérification signature ---
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
    
    # --- Vérification notarisation Apple ---
    log "Verifying Apple notarization..."
    NOTARIZE_RESULT=\$(spctl -a -vv -t install "\$SOURCE_APP" 2>&1 || true)
    echo "\$NOTARIZE_RESULT" | tee -a "\$LOG"
    if ! echo "\$NOTARIZE_RESULT" | grep -q "accepted"; then
        log "[ERROR] App is not notarized by Apple — aborting"
        exit 1
    fi
    log "Notarization: OK"
    
    # --- Quit gracieux de CCC s'il tourne ---
    if pgrep -x "Carbon Copy Cloner" > /dev/null; then
        log "CCC is running — asking it to quit gracefully..."
        osascript -e 'tell application "Carbon Copy Cloner" to quit' 2>/dev/null || true
        
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            if ! pgrep -x "Carbon Copy Cloner" > /dev/null; then
                log "CCC quit cleanly after \$((i*2))s"
                break
            fi
            sleep 2
        done
        
        if pgrep -x "Carbon Copy Cloner" > /dev/null; then
            log "[WARN] CCC did not quit gracefully — force killing"
            pkill -9 -x "Carbon Copy Cloner" 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # --- Installation : copie de l'app dans /Applications ---
    log "Installing to /Applications/..."
    if [ -d "\$APP_PATH" ]; then
        rm -rf "\$APP_PATH"
    fi
    
    cp -R "\$SOURCE_APP" "/Applications/" || {
        log "[ERROR] Copy failed"
        exit 1
    }
    
    # On peut effacer l'extract dir maintenant que l'app est dans /Applications
    rm -rf "\$EXTRACT_DIR"
    log "Extracted files removed (app already copied)"
    
    # --- Vérification post-install ---
    if [ ! -d "\$APP_PATH" ]; then
        log "[ERROR] App not found after copy"
        exit 1
    fi
    
    NEW_INSTALLED=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "FAILED")
    log "Installation verified: \$NEW_INSTALLED"
fi

# --- Désactivation Sparkle (toujours, même si SKIP_INSTALL=1) ---
log "Disabling Sparkle auto-update..."
defaults write /Library/Preferences/com.bombich.ccc SUEnableAutomaticChecks -bool false
defaults write /Library/Preferences/com.bombich.ccc SUAutomaticallyUpdate -bool false
log "Sparkle disabled (system-wide via /Library/Preferences/com.bombich.ccc)"

log "=== Carbon Copy Cloner install/update successful ==="
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ postinstall embedded with version $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ Postinstall will: download → verify → install → cleanup${NC}"
echo ""

# --- Étape 3 : Build PKG (stub avec --root sur dossier vide pour générer un receipt) ---
echo -e "${BLUE}[3/4] Building PKG (stub)...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

# Création du dossier vide qui sert de "racine du payload".
# Avec --root sur un dossier vide :
#   - Le PKG ne contient AUCUN fichier à installer (reste léger ~10 KB)
#   - MAIS macOS enregistre quand même un receipt dans /var/db/receipts/
#   - Ce receipt est utile pour la traçabilité et les inventaires de conformité
mkdir -p "$EMPTY_PAYLOAD_ROOT"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$LATEST_VERSION" \
    --root "$EMPTY_PAYLOAD_ROOT" \
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
    echo -e "${RED}[ERROR] Invalid SHA-256 computed${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 4 : Update YAML ---
echo -e "${BLUE}[4/4] Updating carbon_copy_cloner.yml...${NC}"

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
echo ""

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$LATEST_VERSION"
        echo "build_version=$BUILD_VERSION"
        echo "filename=$ZIP_FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

# --- Récap ---
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  ZIP filename   : $ZIP_FILENAME"
echo "  Build version  : $BUILD_VERSION"
echo "  PKG version    : $LATEST_VERSION (3 segments, matches app Info.plist)"
echo "  PKG identifier : $PKG_IDENTIFIER (matches app bundle ID for Fleet)"
echo "  PKG path       : $OUTPUT_PKG"
echo "  PKG size       : $PKG_SIZE"
echo "  SHA256         : $PKG_HASH"
echo "  TeamID         : $EXPECTED_TEAM_ID"
echo ""
