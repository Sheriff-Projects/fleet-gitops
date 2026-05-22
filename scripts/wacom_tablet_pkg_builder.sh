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
XML_URL="https://link.wacom.com/wdc/update.xml"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
REPO="Sheriff-Projects/fleet-gitops"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/macos/download/wacom_tablet.pkg"

# Identifier qui matche le bundle ID de Wacom Center.app
# pour que Fleet détecte la version installée et affiche le bouton Uninstall.
PKG_IDENTIFIER="com.wacom.WacomCenter"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"
DOWNLOAD_DIR="$REPO_ROOT/lib/macos/download"
OUTPUT_PKG="$DOWNLOAD_DIR/wacom_tablet.pkg"
SOFTWARE_DIR="$REPO_ROOT/lib/macos/software"
YAML_FILE="$SOFTWARE_DIR/wacom_tablet.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_wacom_tablet.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_wacom_tablet.sh"

APP_PATH="/Applications/Wacom Tablet.localized/Wacom Center.app"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Wacom Tablet — PKG Builder (CI/local)  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Fetch version ---
echo -e "${BLUE}[1/5] Fetching latest Wacom Tablet version...${NC}"

XML_CONTENT=$(curl -s "$XML_URL")
MAC_SECTION=$(echo "$XML_CONTENT" | perl -0777 -ne 'print $1 if /<mac type="map">(.*?)<\/mac>/s')
FILENAME=$(perl -ne 'if (/<file type="string">(.*?\.dmg)<\/file>/) { print $1; exit }' <<< "$MAC_SECTION")
URL_BASE=$(echo "$MAC_SECTION" | perl -0777 -ne 'if (/<file type="string">'"$FILENAME"'<\/file>\s*<url type="string">(.*?)<\/url>/s) { print $1; exit }')
DOWNLOAD_URL="${URL_BASE}${FILENAME}"
LATEST_VERSION=$(echo "$FILENAME" | sed -nE 's/^[A-Za-z_]+_([0-9.]+(-[0-9]+)?)\.dmg$/\1/p')
PKG_VERSION="$LATEST_VERSION"

echo -e "${GREEN}  ✓ DMG filename: $FILENAME${NC}"
echo -e "${GREEN}  ✓ Full URL:     $DOWNLOAD_URL${NC}"
echo -e "${GREEN}  ✓ PKG version:  $PKG_VERSION${NC}"
echo ""

# --- Étape 2 : Stub PKG sans logique réelle ---
echo -e "${BLUE}[2/5] Generating no-op postinstall...${NC}"

mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# No-op postinstall — la vraie installation est dans install_wacom_tablet.sh
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Wacom stub PKG installed (no-op)" >> /var/log/wacom_tablet_install.log
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
    echo -e "${RED}[ERROR] PKG build failed${NC}"; exit 1
fi

PKG_SIZE=$(du -h "$OUTPUT_PKG" | awk '{print $1}')
PKG_HASH=$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 4 : install_wacom_tablet.sh ---
echo -e "${BLUE}[4/5] Generating Fleet install script (real install logic)...${NC}"

mkdir -p "$SOFTWARE_DIR"

cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash
# Install script Wacom Tablet — appelé par Fleet (PAS imbriqué dans un autre installer).
# Télécharge le DMG officiel Wacom, l'installe, puis charge les LaunchAgents
# dans la session GUI de l'utilisateur connecté (pour éviter un redémarrage).

set -uo pipefail

TARGET_VERSION="$PKG_VERSION"
DOWNLOAD_URL="$DOWNLOAD_URL"
APP_PATH="$APP_PATH"
TEMP_DIR=\$(mktemp -d)
DMG_PATH="\$TEMP_DIR/WacomTablet.dmg"
MOUNT_POINT="\$TEMP_DIR/WacomTabletMount"
LOG="/var/log/wacom_tablet_install.log"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
cleanup() {
    hdiutil detach "\$MOUNT_POINT" -force -quiet 2>/dev/null || true
    rm -rf "\$TEMP_DIR"
}
trap cleanup EXIT

log "=== Wacom Tablet install/update started (Fleet script) ==="
log "Target version: \$TARGET_VERSION"

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

log "Downloading from \$DOWNLOAD_URL..."
if ! curl -sSL --fail --max-time 1800 "\$DOWNLOAD_URL" -o "\$DMG_PATH"; then
    log "[ERROR] Download failed"; exit 1
fi

log "Mounting DMG..."
mkdir -p "\$MOUNT_POINT"
if ! hdiutil attach "\$DMG_PATH" -mountpoint "\$MOUNT_POINT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount DMG"; exit 1
fi

SOURCE_PKG=\$(find "\$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -type f 2>/dev/null | head -n 1)
if [ -z "\$SOURCE_PKG" ] || [ ! -f "\$SOURCE_PKG" ]; then
    log "[ERROR] Aucun .pkg trouvé dans le DMG"
    ls -la "\$MOUNT_POINT" | tee -a "\$LOG"
    exit 1
fi
log "Embedded PKG: \$SOURCE_PKG"

log "Running installer -pkg ..."
if ! installer -pkg "\$SOURCE_PKG" -target / >> "\$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- Chargement des LaunchDaemons (root, pas de session requise) ---
log "Loading Wacom LaunchDaemons..."
for daemon in /Library/LaunchDaemons/com.wacom.*.plist; do
    [ -e "\$daemon" ] || continue
    log "  bootstrap \$daemon"
    launchctl bootstrap system "\$daemon" 2>/dev/null \\
        || launchctl load "\$daemon" 2>/dev/null \\
        || true
done

# --- Chargement des LaunchAgents dans la session GUI de l'utilisateur connecté ---
# C'est cette étape qui évite le redémarrage : sans elle, les agents (dont l'icône
# de la barre de menu) ne se chargeraient qu'au prochain login.
log "Loading Wacom LaunchAgents in user GUI session..."
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")

if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
    log "  Target user: \$CONSOLE_USER (uid=\$CONSOLE_UID)"
    for agent in /Library/LaunchAgents/com.wacom.*.plist; do
        [ -e "\$agent" ] || continue
        log "  bootstrap \$agent"
        # bootstrap = la méthode moderne (Big Sur+)
        # fallback sur asuser+load pour les vieilles versions
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
    log "Installation verified: Wacom Center \$NEW_VERSION"
else
    log "[WARN] \$APP_PATH not found after install"
fi

log "=== Wacom Tablet install/update successful ==="
exit 0
EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $INSTALL_SCRIPT${NC}"

cat > "$UNINSTALL_SCRIPT" << EOF
#!/bin/bash
# Uninstall script Wacom Tablet
set -o pipefail
LOG="/var/log/wacom_tablet_uninstall.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
log "=== Wacom Tablet uninstall started ==="

# Détection de l'utilisateur, robuste même quand le script tourne via fleetd
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="\${SUDO_USER:-\${CONSOLE_USER:-\${USER:-root}}}"
log "Running as REAL_USER=\$REAL_USER (CONSOLE_USER=\$CONSOLE_USER)"

ProgramList=("WacomTabletDriver" "WacomTouchDriver" "TabletDriver" "Wacom Tablet Utility" "Wacom Desktop Center" "Wacom Center" "Wacom Experience Program" "UpgradeHelper" "Wacom_IOManager" "com.wacom.UpdateHelper" "com.wacom.DataStoreMgr")
for p in "\${ProgramList[@]}"; do
    PIDS=\$(pgrep -f "\$p" 2>/dev/null || true)
    for pid in \$PIDS; do log "  kill \$p (\$pid)"; kill -9 "\$pid" 2>/dev/null || true; done
done
sleep 1

# Unload des LaunchAgents — préférer bootout dans le domaine GUI de l'utilisateur
for a in /Library/LaunchAgents/com.wacom.DataStoreMgr.plist /Library/LaunchAgents/com.wacom.wacomtablet.plist /Library/LaunchAgents/com.wacom.DisplayMgr.plist /Library/LaunchAgents/com.wacom.IOManager.plist; do
    [ -e "\$a" ] || continue
    log "  unload agent \$a"
    if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/\$CONSOLE_UID" "\$a" 2>/dev/null \\
            || launchctl asuser "\$CONSOLE_UID" launchctl unload "\$a" 2>/dev/null \\
            || true
    fi
done

# Unload des LaunchDaemons
for d in /Library/LaunchDaemons/com.wacom.DisplayHelper.plist /Library/LaunchDaemons/com.wacom.displayhelper.plist /Library/LaunchDaemons/com.wacom.UpdateHelper.plist /Library/LaunchDaemons/com.wacom.TabletHelper.plist; do
    [ -e "\$d" ] || continue
    log "  unload daemon \$d"
    launchctl bootout system "\$d" 2>/dev/null \\
        || launchctl unload "\$d" 2>/dev/null \\
        || true
done
sleep 1

for k in com.Wacom.iokit.TabletDriver com.wacom.kext.wacomtablet com.wacom.kext.ftdi com.wacom.WacomTabletHIDDevice; do
    /sbin/kextunload -m "\$k" 2>/dev/null || true
done

FilesToRemove=(
    /Library/LaunchAgents/com.wacom.DataStoreMgr.plist
    /Library/LaunchAgents/com.wacom.wacomtablet.plist
    /Library/LaunchAgents/com.wacom.DisplayMgr.plist
    /Library/LaunchAgents/com.wacom.IOManager.plist
    /Library/LaunchDaemons/com.wacom.DisplayHelper.plist
    /Library/LaunchDaemons/com.wacom.displayhelper.plist
    /Library/LaunchDaemons/com.wacom.UpdateHelper.plist
    /Library/LaunchDaemons/com.wacom.TabletHelper.plist
    "/Applications/Wacom Tablet.localized"
    /Applications/WacomTablet
    /Applications/Tablet.localized
    "/Library/Application Support/Tablet"
    /Library/PreferencePanes/WacomTablet.prefPane
    "/Library/PreferencePanes/Wacom Tablet.prefPane"
    "/Library/PreferencePanes/Pen Tablet.prefPane"
    /Library/PreferencePanes/Tablet.prefPane
    /Library/PrivilegedHelperTools/com.wacom.TabletHelper.app
    /Library/PrivilegedHelperTools/com.wacom.IOmanager.app
    /Library/PrivilegedHelperTools/com.wacom.UpdateHelper.app
    /Library/PrivilegedHelperTools/com.wacom.DataStoreMgr.app
    /Library/PrivilegedHelperTools/Wacom_IOManager.app
    /Library/Extensions/TabletDriver.kext
    /Library/Extensions/WacomTablet.kext
    "/Library/Internet Plug-Ins/WacomTabletPlugin.plugin"
    "/Library/Internet Plug-Ins/WacomSafari.plugin"
    /Library/Preferences/Tablet
)
for f in "\${FilesToRemove[@]}"; do
    if [ -e "\$f" ] || [ -L "\$f" ]; then
        log "  rm \$f"; rm -rf "\$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout prefPane qui matche wacom/tablet
log "Sweeping leftover Wacom prefPanes..."
find /Library/PreferencePanes -maxdepth 1 -iname "*wacom*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/PreferencePanes -maxdepth 1 -iname "*tablet*" -exec rm -rf {} \\; 2>/dev/null || true

for userdir in /Users/*; do
    [ -d "\$userdir" ] || continue
    [ "\$(basename "\$userdir")" = "Shared" ] && continue
    for path in \\
        "\$userdir/Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver" \\
        "\$userdir/Library/Group Containers/group.EG27766DY7.com.wacom.WacomTabletDriver" \\
        "\$userdir/Library/Group Containers/group.com.wacom.TabletDriver" \\
        "\$userdir/Library/Containers/com.wacom.wacomtablet" \\
        "\$userdir/Library/Application Support/Wacom" \\
        "\$userdir/Library/Preferences/com.wacom.Wacom-Desktop-Center.plist"
    do
        if [ -e "\$path" ] || [ -L "\$path" ]; then
            log "  rm \$path"; rm -rf "\$path" 2>/dev/null || true
        fi
    done
done

WacomPkgs=\$(pkgutil --pkgs | grep -i wacom || true)
if [ -n "\$WacomPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget \$pkg"
        pkgutil --forget "\$pkg" 2>/dev/null || true
    done <<< "\$WacomPkgs"
fi
pkgutil --forget "$PKG_IDENTIFIER" 2>/dev/null || true

# --- Vider le cache de Réglages Système (icône fantôme) ---
log "Clearing System Settings cache..."
killall "System Preferences" 2>/dev/null || true
killall "System Settings" 2>/dev/null || true

# Le cache de l'utilisateur connecté (CONSOLE_USER déjà détecté en haut)
if [ -n "\$CONSOLE_USER" ] && [ "\$CONSOLE_USER" != "root" ]; then
    CONSOLE_HOME=\$(eval echo ~"\$CONSOLE_USER")
    rm -rf "\$CONSOLE_HOME/Library/Caches/com.apple.preferencepanes.usercache" 2>/dev/null || true
    rm -rf "\$CONSOLE_HOME/Library/Caches/com.apple.systempreferences" 2>/dev/null || true
    sudo -u "\$CONSOLE_USER" killall cfprefsd 2>/dev/null || true
fi

# Aussi pour root au cas où
rm -rf /var/root/Library/Caches/com.apple.preferencepanes.usercache 2>/dev/null || true
rm -rf /var/root/Library/Caches/com.apple.systempreferences 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

log "  Cache cleared"

log "=== Wacom Tablet uninstall finished ==="
exit 0
EOF
chmod +x "$UNINSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $UNINSTALL_SCRIPT${NC}"
echo ""

# --- Étape 5 : YAML ---
echo -e "${BLUE}[5/5] Updating wacom_tablet.yml...${NC}"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icons/wacom_tablet.png
  install_script:
    path: ./install_wacom_tablet.sh
  uninstall_script:
    path: ./uninstall_wacom_tablet.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"
echo ""

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

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$LATEST_VERSION"
        ...
    } >> "$GITHUB_OUTPUT"
fi

# ===========================================================================
# Auto-commit + push (cible : branche main)
# ===========================================================================
echo -e "${BLUE}[*] Auto-commit + push...${NC}"

cd "$REPO_ROOT"

# Stage uniquement le .pkg + le YAML pour ne pas embarquer d'autres changements
git add "$OUTPUT_PKG" "$YAML_FILE"

if git diff --staged --quiet; then
    echo -e "${YELLOW}  ⚠ Aucun changement à committer${NC}"
else
    COMMIT_MSG="package release: $(basename "$OUTPUT_PKG" .pkg) $LATEST_VERSION"
    git commit -m "$COMMIT_MSG"
    git push
    echo -e "${GREEN}  ✓ Pushed: $COMMIT_MSG${NC}"
fi
echo ""

# ===========================================================================
# Auto-commit + push (cible : branche main)
# ===========================================================================
echo -e "${BLUE}[*] Auto-commit + push...${NC}"
... (le snippet ici)
echo ""

# --- Récap ---

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
echo ""
echo "  Note : après installer -pkg, le script charge les LaunchAgents Wacom"
echo "  dans la session GUI de l'utilisateur connecté — l'icône de la barre"
echo "  de menu et Wacom Center démarrent sans redémarrage."
echo " 
echo " 
gh workflow run release-new-packages.yml
echo -e "${GREEN}  ✓ Workflow Release déclenché${NC}"