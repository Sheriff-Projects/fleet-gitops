#!/bin/bash
clear
set -euo pipefail

# --- Couleurs ---
if [ -t 1 ]; then
    GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; BLUE=''; YELLOW=''; RED=''; NC=''
fi

# --- Configuration ---
JSON_URL="https://www.eizo.co.jp/update/cn7-update-v2-global.json"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
REPO="souari1974/fleet-gitops"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/color_navigator.pkg"

# Identifier qui matche le bundle ID de ColorNavigator 7.app
# pour que Fleet détecte la version installée et affiche le bouton Uninstall.
PKG_IDENTIFIER="jp.co.eizo.ColorNavigator7"

EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/eizo_color_navigator.pkg"
SOFTWARE_DIR="$REPO_ROOT/lib/unassigned/software"
YAML_FILE="$SOFTWARE_DIR/color_navigator.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_color_navigator.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_color_navigator.sh"

APP_PATH="/Applications/ColorNavigator 7.app"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   EIZO ColorNavigator 7 — PKG Builder        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Fetch version depuis le JSON EIZO ---
echo -e "${BLUE}[1/5] Fetching latest ColorNavigator version...${NC}"

# Vérifie que jq est disponible (devrait être présent sur GitHub runners et macOS récents)
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] jq n'est pas installé. Installe-le via: brew install jq${NC}"
    exit 1
fi

JSON_CONTENT=$(curl -sSL --fail "$JSON_URL")
if [ -z "$JSON_CONTENT" ]; then
    echo -e "${RED}[ERROR] Impossible de récupérer le JSON EIZO${NC}"
    exit 1
fi

# Parse JSON : Root -> application -> mac -> url & version
DOWNLOAD_URL=$(echo "$JSON_CONTENT" | jq -r '.application.mac.url')
LATEST_VERSION=$(echo "$JSON_CONTENT" | jq -r '.application.mac.version')
FILENAME=$(basename "$DOWNLOAD_URL")
PKG_VERSION="$LATEST_VERSION"

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    echo -e "${RED}[ERROR] URL non trouvée dans le JSON${NC}"
    exit 1
fi
if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    echo -e "${RED}[ERROR] Version non trouvée dans le JSON${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ PKG filename: $FILENAME${NC}"
echo -e "${GREEN}  ✓ Full URL:     $DOWNLOAD_URL${NC}"
echo -e "${GREEN}  ✓ PKG version:  $PKG_VERSION${NC}"
echo ""

# --- Étape 2 : Stub PKG sans logique réelle ---
echo -e "${BLUE}[2/5] Generating no-op postinstall...${NC}"

mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# No-op postinstall — la vraie installation est dans install_color_navigator.sh
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] EIZO ColorNavigator stub PKG installed (no-op)" >> /var/log/eizo_color_navigator_install.log
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ Stub postinstall created${NC}"
echo ""

# --- Étape 3 : Build PKG (stub) ---
echo -e "${BLUE}[3/5] Building stub PKG...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"
mkdir -p "$EMPTY_PAYLOAD_ROOT"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$LATEST_VERSION" \
    --root "$EMPTY_PAYLOAD_ROOT" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>EIZO ColorNavigator 7</title>
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
    echo -e "${RED}[ERROR] PKG build failed${NC}"; exit 1
fi

PKG_SIZE=$(du -h "$OUTPUT_PKG" | awk '{print $1}')
PKG_HASH=$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 4 : install_eizo_color_navigator.sh ---
echo -e "${BLUE}[4/5] Generating Fleet install script...${NC}"

mkdir -p "$SOFTWARE_DIR"

cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash
# Install script EIZO ColorNavigator 7 — appelé par Fleet.
# Télécharge le PKG officiel EIZO et l'installe directement.

set -uo pipefail

TARGET_VERSION="$PKG_VERSION"
DOWNLOAD_URL="$DOWNLOAD_URL"
APP_PATH="$APP_PATH"
TEMP_DIR=\$(mktemp -d)
PKG_PATH="\$TEMP_DIR/ColorNavigator.pkg"
LOG="/var/log/color_navigator_install.log"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
cleanup() { rm -rf "\$TEMP_DIR"; }
trap cleanup EXIT

log "=== EIZO ColorNavigator install/update started (Fleet script) ==="
log "Target version: \$TARGET_VERSION"

# --- Check version installée ---
if [ -d "\$APP_PATH" ]; then
    INSTALLED_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: \$INSTALLED_VERSION"
    if [ "\$INSTALLED_VERSION" = "\$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from \$INSTALLED_VERSION to \$TARGET_VERSION..."
else
    log "ColorNavigator not installed, performing fresh install..."
fi

# --- Téléchargement du PKG ---
log "Downloading from \$DOWNLOAD_URL..."
if ! curl -sSL --fail --max-time 1800 "\$DOWNLOAD_URL" -o "\$PKG_PATH"; then
    log "[ERROR] Download failed"; exit 1
fi

# --- Vérification basique du fichier ---
if [ ! -s "\$PKG_PATH" ]; then
    log "[ERROR] PKG téléchargé vide ou invalide"
    exit 1
fi
PKG_DL_SIZE=\$(du -h "\$PKG_PATH" | awk '{print \$1}')
log "Downloaded PKG: \$PKG_DL_SIZE"

# --- Installation ---
log "Running installer -pkg ..."
if ! installer -pkg "\$PKG_PATH" -target / >> "\$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- Chargement des LaunchDaemons EIZO (root) ---
log "Loading EIZO LaunchDaemons (if any)..."
for daemon in /Library/LaunchDaemons/jp.co.eizo.*.plist; do
    [ -e "\$daemon" ] || continue
    log "  bootstrap \$daemon"
    launchctl bootstrap system "\$daemon" 2>/dev/null \\
        || launchctl load "\$daemon" 2>/dev/null \\
        || true
done

# --- Chargement des LaunchAgents EIZO dans la session GUI ---
log "Loading EIZO LaunchAgents in user GUI session..."
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")

if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
    log "  Target user: \$CONSOLE_USER (uid=\$CONSOLE_UID)"
    for agent in /Library/LaunchAgents/jp.co.eizo.*.plist; do
        [ -e "\$agent" ] || continue
        log "  bootstrap \$agent"
        launchctl bootstrap "gui/\$CONSOLE_UID" "\$agent" 2>/dev/null \\
            || launchctl asuser "\$CONSOLE_UID" launchctl load "\$agent" 2>/dev/null \\
            || true
    done
else
    log "  [WARN] Aucun utilisateur connecté en GUI — agents chargés au prochain login"
fi

# --- Vérification post-install ---
if [ -d "\$APP_PATH" ]; then
    NEW_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: ColorNavigator \$NEW_VERSION"
else
    log "[WARN] \$APP_PATH not found after install"
fi

log "=== EIZO ColorNavigator install/update successful ==="
exit 0
EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $INSTALL_SCRIPT${NC}"

cat > "$UNINSTALL_SCRIPT" << EOF
#!/bin/bash
# Uninstall script EIZO ColorNavigator 7
set -o pipefail
LOG="/var/log/color_navigator_uninstall.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
log "=== EIZO ColorNavigator uninstall started ==="

# Détection de l'utilisateur, robuste même quand le script tourne via fleetd
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="\${SUDO_USER:-\${CONSOLE_USER:-\${USER:-root}}}"
log "Running as REAL_USER=\$REAL_USER (CONSOLE_USER=\$CONSOLE_USER)"

# --- 1. Kill running EIZO/ColorNavigator processes ---
ProgramList=("ColorNavigator" "ColorNavigator 7" "ColorNavigatorAgent" "ColorNavigatorNetworkClient" "EIZO")
for p in "\${ProgramList[@]}"; do
    PIDS=\$(pgrep -f "\$p" 2>/dev/null || true)
    for pid in \$PIDS; do log "  kill \$p (\$pid)"; kill -9 "\$pid" 2>/dev/null || true; done
done
sleep 1

# --- 2. Unload des LaunchAgents EIZO ---
for a in /Library/LaunchAgents/jp.co.eizo.*.plist; do
    [ -e "\$a" ] || continue
    log "  unload agent \$a"
    if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/\$CONSOLE_UID" "\$a" 2>/dev/null \\
            || launchctl asuser "\$CONSOLE_UID" launchctl unload "\$a" 2>/dev/null \\
            || true
    fi
done

# --- 3. Unload des LaunchDaemons EIZO ---
for d in /Library/LaunchDaemons/jp.co.eizo.*.plist; do
    [ -e "\$d" ] || continue
    log "  unload daemon \$d"
    launchctl bootout system "\$d" 2>/dev/null \\
        || launchctl unload "\$d" 2>/dev/null \\
        || true
done
sleep 1

# --- 4. Suppression des fichiers ---
FilesToRemove=(
    "/Applications/ColorNavigator 7.app"
    "/Applications/ColorNavigator.app"
    "/Library/Application Support/EIZO"
    "/Library/Application Support/ColorNavigator"
    "/Library/Application Support/ColorNavigator 7"
    "/Library/Preferences/jp.co.eizo.ColorNavigator7.plist"
    "/Library/PrivilegedHelperTools/jp.co.eizo.ColorNavigator7Helper"
)
for f in "\${FilesToRemove[@]}"; do
    if [ -e "\$f" ] || [ -L "\$f" ]; then
        log "  rm \$f"; rm -rf "\$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout fichier EIZO restant dans /Library
log "Sweeping leftover EIZO files..."
find /Library/LaunchAgents -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \\; 2>/dev/null || true

# --- 5. Cleanup ~/Library de tous les utilisateurs ---
for userdir in /Users/*; do
    [ -d "\$userdir" ] || continue
    [ "\$(basename "\$userdir")" = "Shared" ] && continue
    for path in \\
        "\$userdir/Library/Application Support/EIZO" \\
        "\$userdir/Library/Application Support/ColorNavigator" \\
        "\$userdir/Library/Application Support/ColorNavigator 7" \\
        "\$userdir/Library/Preferences/jp.co.eizo.ColorNavigator7.plist" \\
        "\$userdir/Library/Preferences/jp.co.eizo.ColorNavigator.plist" \\
        "\$userdir/Library/Caches/jp.co.eizo.ColorNavigator7" \\
        "\$userdir/Library/Caches/jp.co.eizo.ColorNavigator"
    do
        if [ -e "\$path" ] || [ -L "\$path" ]; then
            log "  rm \$path"; rm -rf "\$path" 2>/dev/null || true
        fi
    done
done

# --- 6. Forget pkg receipts ---
EizoPkgs=\$(pkgutil --pkgs | grep -iE "eizo|colornavigator" || true)
if [ -n "\$EizoPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget \$pkg"
        pkgutil --forget "\$pkg" 2>/dev/null || true
    done <<< "\$EizoPkgs"
fi
pkgutil --forget "$PKG_IDENTIFIER" 2>/dev/null || true

# --- 7. Vider le cache de Réglages Système ---
log "Clearing System Settings cache..."
killall "System Preferences" 2>/dev/null || true
killall "System Settings" 2>/dev/null || true

if [ -n "\$CONSOLE_USER" ] && [ "\$CONSOLE_USER" != "root" ]; then
    CONSOLE_HOME=\$(eval echo ~"\$CONSOLE_USER")
    rm -rf "\$CONSOLE_HOME/Library/Caches/com.apple.preferencepanes.usercache" 2>/dev/null || true
    rm -rf "\$CONSOLE_HOME/Library/Caches/com.apple.systempreferences" 2>/dev/null || true
    sudo -u "\$CONSOLE_USER" killall cfprefsd 2>/dev/null || true
fi

rm -rf /var/root/Library/Caches/com.apple.preferencepanes.usercache 2>/dev/null || true
rm -rf /var/root/Library/Caches/com.apple.systempreferences 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

log "  Cache cleared"

log "=== EIZO ColorNavigator uninstall finished ==="
exit 0
EOF
chmod +x "$UNINSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $UNINSTALL_SCRIPT${NC}"
echo ""

# --- Étape 5 : YAML ---
echo -e "${BLUE}[5/5] Updating eizo_color_navigator.yml...${NC}"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icon/eizo_color_navigator.png
  install_script:
    path: ./install_eizo_color_navigator.sh
  uninstall_script:
    path: ./uninstall_eizo_color_navigator.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"
echo ""

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$PKG_VERSION"
        echo "filename=$FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  PKG version      : $PKG_VERSION"
echo "  PKG identifier   : $PKG_IDENTIFIER"
echo "  PKG path         : $OUTPUT_PKG"
echo "  PKG size         : $PKG_SIZE"
echo "  SHA256           : $PKG_HASH"
echo "  Install script   : $INSTALL_SCRIPT"
echo "  Uninstall script : $UNINSTALL_SCRIPT"
echo "  YAML             : $YAML_FILE"
echo ""
echo "  Note : EIZO sert un .pkg direct (pas de DMG à monter), donc"
echo "  l'install est plus simple que Wacom. La logique reste dans le"
echo "  script Fleet (pas dans le postinstall) pour éviter l'imbrication"
echo "  d'installers."