#!/bin/bash
# Build le PKG Carbon Copy Cloner avec la dernière version embarquée.
# Le PKG est versionné dans Git, URL fixe via raw.githubusercontent.com.
#
# Le PKG produit est un "stub" : pas de payload, juste un postinstall qui
# télécharge le ZIP officiel Bombich et installe Carbon Copy Cloner.app.
#
# Spécificités CCC vs Capture One :
#   - Source : ZIP au lieu de DMG (pas de hdiutil, juste unzip)
#   - URL : ?v=latest (constante, pas de feed XML à parser)
#   - Désactivation de l'auto-update Sparkle natif de CCC après install
#   - Version inconnue avant download → on télécharge, extrait, lit Info.plist
#
# Usage local :
#   ./scripts/carbon_copy_cloner_pkg_builder.sh
# Usage CI (déjà configuré dans le workflow) :
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
DOWNLOAD_URL="https://bombich.scdn1.secure.raxcdn.com/software/download_ccc.php?v=latest"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/carbon_copy_cloner.pkg"
REPO="souari1974/fleet-gitops"
YAML_FILE="$REPO_ROOT/lib/unassigned/software/carbon_copy_cloner.yml"

# URL fixe (ne change jamais entre les versions)
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/carbon_copy_cloner.pkg"

# Identifiant Apple Developer Team de Bombich Software, Inc.
# À vérifier une fois via : codesign -dvv "/Applications/Carbon Copy Cloner.app" 2>&1 | grep TeamIdentifier
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"

PKG_IDENTIFIER="com.bombich.ccc.pkg"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$BUILD_DIR" "$WORK_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Carbon Copy Cloner — PKG Builder        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Download + extract pour lire la version ---
# Spécificité CCC : pas de feed XML, on doit télécharger pour connaître la version.
# C'est moins efficace que Capture One mais c'est le seul moyen avec Bombich.
echo -e "${BLUE}[1/4] Downloading CCC to detect version...${NC}"

ZIP_PATH="$WORK_DIR/ccc.zip"
EXTRACT_DIR="$WORK_DIR/extracted"

curl -sSL --fail --max-time 600 "$DOWNLOAD_URL" -o "$ZIP_PATH" || {
    echo -e "${RED}[ERROR] Failed to download CCC zip from Bombich${NC}"
    exit 1
}

ZIP_SIZE=$(du -h "$ZIP_PATH" | awk '{print $1}')
echo -e "${GREEN}  ✓ ZIP downloaded: $ZIP_SIZE${NC}"

mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR" || {
    echo -e "${RED}[ERROR] Failed to unzip CCC archive${NC}"
    exit 1
}

CCC_APP="$EXTRACT_DIR/Carbon Copy Cloner.app"
if [ ! -d "$CCC_APP" ]; then
    echo -e "${RED}[ERROR] Carbon Copy Cloner.app not found in zip${NC}"
    echo "Contents of zip:"
    ls -la "$EXTRACT_DIR"
    exit 1
fi

# Lecture de la version réelle depuis Info.plist
LATEST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CCC_APP/Contents/Info.plist" 2>/dev/null || echo "")
APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CCC_APP/Contents/Info.plist" 2>/dev/null || echo "")

if [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}[ERROR] Unable to read CCC version from Info.plist${NC}"
    exit 1
fi

if [ "$APP_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
    echo -e "${RED}[ERROR] Unexpected bundle ID: $APP_BUNDLE_ID (expected $EXPECTED_BUNDLE_ID)${NC}"
    exit 1
fi

# Sanity check signature au build time aussi (en plus du check à l'install)
APP_TEAM_ID=$(codesign -dvv "$CCC_APP" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
if [ "$APP_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
    echo -e "${RED}[ERROR] Unexpected TeamID at build time: $APP_TEAM_ID (expected $EXPECTED_TEAM_ID)${NC}"
    echo -e "${YELLOW}If this is the first run and Bombich genuinely changed their TeamID, update EXPECTED_TEAM_ID in this script.${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ Version:    $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ Bundle ID:  $APP_BUNDLE_ID${NC}"
echo -e "${GREEN}  ✓ Team ID:    $APP_TEAM_ID${NC}"
echo ""

# --- Étape 2 : Prepare postinstall ---
echo -e "${BLUE}[2/4] Preparing postinstall script...${NC}"

mkdir -p "$SCRIPTS_DIR"

# IMPORTANT sur l'échappement dans le heredoc :
#   $VAR    → expansé MAINTENANT (build time), valeur hardcodée dans le postinstall
#   \$VAR   → expansé À L'EXÉCUTION du postinstall (install time, sur le Mac client)
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# Carbon Copy Cloner installer — built on $(date '+%Y-%m-%d %H:%M:%S')
# Target version: $LATEST_VERSION
# Expected TeamIdentifier: $EXPECTED_TEAM_ID (Bombich Software, Inc.)

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

cleanup() {
    rm -rf "\$TEMP_DIR"
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
        log "Already up to date. Just refreshing Sparkle settings."
        # On n'exit pas tout de suite, on va quand même réappliquer les prefs Sparkle
        # au cas où l'utilisateur les aurait changées
        SKIP_INSTALL=1
    else
        SKIP_INSTALL=0
        log "Upgrading from \$INSTALLED_VERSION to \$TARGET_VERSION..."
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
    log "ZIP downloaded: \$ZIP_SIZE"
    
    # --- Extraction ZIP ---
    log "Extracting ZIP..."
    mkdir -p "\$EXTRACT_DIR"
    unzip -q "\$ZIP_PATH" -d "\$EXTRACT_DIR" || {
        log "[ERROR] Failed to extract ZIP"
        exit 1
    }
    
    SOURCE_APP="\$EXTRACT_DIR/Carbon Copy Cloner.app"
    if [ ! -d "\$SOURCE_APP" ]; then
        log "[ERROR] Carbon Copy Cloner.app not found in ZIP"
        log "[ERROR] ZIP content:"
        ls -la "\$EXTRACT_DIR" | tee -a "\$LOG"
        exit 1
    fi
    
    # --- Vérification version cohérente ---
    # Bombich utilise ?v=latest qui pointe vers la dernière version DU MOMENT de l'install
    # Si Bombich a release une nouvelle version entre le build du PKG et l'install,
    # la version effectivement téléchargée pourrait différer du target_version.
    # On le tolère mais on log l'écart.
    DOWNLOADED_VERSION=\$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "\$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "\$DOWNLOADED_VERSION" != "\$TARGET_VERSION" ]; then
        log "[INFO] Version downloaded (\$DOWNLOADED_VERSION) differs from PKG target (\$TARGET_VERSION)"
        log "[INFO] Bombich released a newer version between build and install — proceeding with \$DOWNLOADED_VERSION"
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
    
    # --- Installation ---
    log "Installing..."
    if [ -d "\$APP_PATH" ]; then
        rm -rf "\$APP_PATH"
    fi
    
    cp -R "\$SOURCE_APP" "/Applications/" || {
        log "[ERROR] Copy failed"
        exit 1
    }
    
    # --- Vérification post-install ---
    if [ ! -d "\$APP_PATH" ]; then
        log "[ERROR] App not found after copy"
        exit 1
    fi
    
    NEW_INSTALLED=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "FAILED")
    log "Installation verified: \$NEW_INSTALLED"
fi

# --- Désactivation de l'auto-update Sparkle (toujours, même si SKIP_INSTALL=1) ---
# Note importante : le postinstall tourne en root.
# On écrit donc dans /Library/Preferences/ pour que ça s'applique à tous les utilisateurs.
# Il y a deux clés possibles selon la version de Sparkle utilisée par CCC :
#   - SUEnableAutomaticChecks : désactive la vérif périodique
#   - SUAutomaticallyUpdate   : désactive l'install automatique
log "Disabling Sparkle auto-update..."
defaults write /Library/Preferences/com.bombich.ccc SUEnableAutomaticChecks -bool false
defaults write /Library/Preferences/com.bombich.ccc SUAutomaticallyUpdate -bool false
log "Sparkle disabled (system-wide via /Library/Preferences/com.bombich.ccc)"

# Note: pour un verrouillage total, déployer aussi un Configuration Profile
# .mobileconfig via Fleet/MDM avec PayloadType "com.apple.ManagedClient.preferences"
# pour le domaine "com.bombich.ccc" et les clés ci-dessus en forced=true.
# Sans ça, un utilisateur peut techniquement réactiver les checks dans CCC.

log "=== Carbon Copy Cloner install/update successful ==="
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ postinstall embedded with version $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ Strict checks enabled (TeamID $EXPECTED_TEAM_ID, notarisation, bundle ID)${NC}"
echo -e "${GREEN}  ✓ Sparkle auto-update will be disabled${NC}"
echo ""

# --- Étape 3 : Build PKG ---
echo -e "${BLUE}[3/4] Building PKG...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

# Construire d'abord un PKG composant.
# On utilise --root sur un dossier vide (au lieu de --nopayload) pour que
# pkgbuild génère un receipt enregistré dans /var/db/receipts/ après install.
# Sans receipt, Fleet ne peut pas faire le lien entre le PKG installé et
# l'app présente sur l'host → pas de bouton Uninstall en self-service.
# Le dossier vide signifie "aucun fichier à installer", le travail réel est
# fait par le postinstall qui télécharge et copie l'app.
COMPONENT_PKG="$BUILD_DIR/component.pkg"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"
mkdir -p "$EMPTY_PAYLOAD_ROOT"

pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$LATEST_VERSION" \
    --root "$EMPTY_PAYLOAD_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

# Construire un Distribution.xml qui définit le titre affiché dans Installer.app
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
    echo -e "${RED}[ERROR] Invalid SHA-256 computed: '$PKG_HASH'${NC}"
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
