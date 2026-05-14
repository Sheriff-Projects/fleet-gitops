#!/bin/bash
# Build le PKG stub FortiClient.
# Le PKG est versionné dans Git, URL fixe via raw.githubusercontent.com.
#
# Particularité FortiClient : double étape de téléchargement.
#   1. On télécharge le "online installer" (~5 Mo, FortiClientVPN_x.y.z.dmg)
#   2. On le monte, on lance FortiClientInstaller.app/Contents/MacOS/FortiClientInstaller
#   3. Cet exécutable télécharge le vrai installer dans /var/folders/.../FortiClient.dmg
#   4. On parse sa sortie pour trouver ce chemin, on monte ce 2e DMG
#   5. On lance installer -pkg Install.mpkg
#
# La version cible (TARGET_VERSION) est résolue DYNAMIQUEMENT à l'exécution
# du script install_forticlient.sh sur le Mac client, via le même mécanisme
# de redirect Fortinet. Donc pas besoin de rebuilder à chaque release Fortinet.

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
DOWNLOAD_URL="https://links.fortinet.com/forticlient/mac/vpnagent"
DOWNLOAD_DIR="$REPO_ROOT/lib/unassigned/download"
OUTPUT_PKG="$DOWNLOAD_DIR/forticlient.pkg"
REPO="souari1974/fleet-gitops"
SOFTWARE_DIR="$REPO_ROOT/lib/unassigned/software"
YAML_FILE="$SOFTWARE_DIR/forticlient.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_forticlient.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_forticlient.sh"

# URL fixe (ne change jamais entre les versions)
PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/forticlient.pkg"

# Identifiants Fortinet
EXPECTED_BUNDLE_ID="com.fortinet.FortiClient"

# IMPORTANT : Le PKG identifier DOIT correspondre exactement au bundle ID de l'app
# pour que Fleet fasse le matching et affiche le bouton Uninstall en self-service.
PKG_IDENTIFIER="com.fortinet.FortiClient"

APP_PATH="/Applications/FortiClient.app"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   FortiClient VPN — PKG Builder          ║${NC}"
echo -e "${BLUE}║   (stub, with Fleet-compatible matching) ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Détection de la version au moment du BUILD ---
# Utilisée uniquement pour figer la version du PKG stub (traçabilité, receipt
# pkgutil). La version EFFECTIVE utilisée pour comparer avec l'app installée
# sera résolue DYNAMIQUEMENT par install_forticlient.sh sur le Mac client.
echo -e "${BLUE}[1/5] Detecting FortiClient version (build-time snapshot)...${NC}"

EFFECTIVE_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "$DOWNLOAD_URL" || echo "")
if [ -z "$EFFECTIVE_URL" ] || [ "$EFFECTIVE_URL" = "$DOWNLOAD_URL" ]; then
    echo -e "${RED}[ERROR] No redirect detected — Fortinet endpoint may have changed${NC}"
    echo -e "${YELLOW}  Original URL:  $DOWNLOAD_URL${NC}"
    echo -e "${YELLOW}  Effective URL: $EFFECTIVE_URL${NC}"
    exit 1
fi

DMG_FILENAME=$(echo "$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
echo -e "${GREEN}  ✓ Effective URL: $EFFECTIVE_URL${NC}"
echo -e "${GREEN}  ✓ DMG filename:  $DMG_FILENAME${NC}"

# Format : FortiClientVPN_7.4.3.4323_OnlineInstaller.dmg → 7.4.3.4323
LATEST_VERSION=$(echo "$DMG_FILENAME" | sed -E 's/^FortiClientVPN_([0-9.]+)_OnlineInstaller\.dmg$/\1/')
if [ "$LATEST_VERSION" = "$DMG_FILENAME" ] || [ -z "$LATEST_VERSION" ]; then
    echo -e "${RED}[ERROR] Filename format unexpected: $DMG_FILENAME${NC}"
    echo -e "${RED}        Expected pattern: FortiClientVPN_VERSION_OnlineInstaller.dmg${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ Build-time version: $LATEST_VERSION${NC}"
echo -e "${YELLOW}  ℹ The install script will resolve the LIVE version at runtime${NC}"
echo ""

# --- Étape 2 : Préparation du stub PKG (no-op postinstall) ---
echo -e "${BLUE}[2/5] Generating no-op postinstall...${NC}"

mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
# No-op postinstall — la vraie installation est dans install_forticlient.sh
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] FortiClient stub PKG installed (no-op)" >> /var/log/forticlient_install.log
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
    <title>FortiClient VPN</title>
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

# --- Étape 4 : Génération des scripts Fleet (install + uninstall) ---
# IMPORTANT sur l'échappement dans le heredoc :
#   $VAR    → expansé MAINTENANT (build time), valeur figée dans le script
#   \$VAR   → expansé À L'EXÉCUTION du script (sur le Mac client, runtime)
#
# Pour la version cible, on veut runtime → \$TARGET_VERSION, résolue à chaque
# exécution Fleet via curl sur l'URL Fortinet.
echo -e "${BLUE}[4/5] Generating Fleet install/uninstall scripts...${NC}"

mkdir -p "$SOFTWARE_DIR"

cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash
# Install script FortiClient VPN — appelé par Fleet (PAS imbriqué dans un autre installer).
#
# Built on $(date '+%Y-%m-%d %H:%M:%S') (build-time snapshot: $LATEST_VERSION)
# Expected Bundle ID: $EXPECTED_BUNDLE_ID
#
# La version cible est résolue DYNAMIQUEMENT à chaque exécution via le redirect
# Fortinet, donc pas besoin de rebuilder le PKG à chaque release Fortinet.
#
# Workflow Fortinet en deux étapes :
#   1. Résoudre l'URL effective (redirect) → version + filename
#   2. Télécharger l'online installer DMG (~5 Mo)
#   3. Le monter, lancer FortiClientInstaller (qui télécharge le vrai installer)
#   4. Parser la sortie pour trouver le path du FortiClient.dmg téléchargé
#   5. Monter ce 2e DMG
#   6. Installer le PKG du second DMG

set -uo pipefail

DOWNLOAD_URL="$DOWNLOAD_URL"
APP_PATH="$APP_PATH"
TEMP_DIR=\$(mktemp -d)
ONLINE_DMG="\$TEMP_DIR/FortiClientVPN_OnlineInstaller.dmg"
ONLINE_MOUNT="\$TEMP_DIR/online_mount"
FC_MOUNT="\$TEMP_DIR/fc_mount"
INSTALLER_LOG="\$TEMP_DIR/forticlient_installer.log"
LOG="/var/log/forticlient_install.log"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }

cleanup() {
    hdiutil detach "\$FC_MOUNT" -force -quiet 2>/dev/null || true
    hdiutil detach "\$ONLINE_MOUNT" -force -quiet 2>/dev/null || true
    [ -d "/Volumes/FortiClientInstaller" ] && hdiutil detach "/Volumes/FortiClientInstaller" -force -quiet 2>/dev/null || true
    [ -d "/Volumes/FortiClient" ] && hdiutil detach "/Volumes/FortiClient" -force -quiet 2>/dev/null || true
    rm -rf "\$TEMP_DIR"
}
trap cleanup EXIT

log "=== FortiClient install/update started (Fleet script) ==="

# --- 1. Résolution dynamique de la version cible via redirect Fortinet ---
log "Resolving live version from Fortinet redirect..."
EFFECTIVE_URL=\$(curl -s -L -w '%{url_effective}' -o /dev/null "\$DOWNLOAD_URL" || echo "")
if [ -z "\$EFFECTIVE_URL" ] || [ "\$EFFECTIVE_URL" = "\$DOWNLOAD_URL" ]; then
    log "[ERROR] No redirect from Fortinet — endpoint may have changed or network is down"
    log "[ERROR] DOWNLOAD_URL=\$DOWNLOAD_URL"
    log "[ERROR] EFFECTIVE_URL=\$EFFECTIVE_URL"
    exit 1
fi

DMG_FILENAME=\$(echo "\$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
# Format : FortiClientVPN_7.4.3.4323_OnlineInstaller.dmg → 7.4.3.4323
TARGET_VERSION=\$(echo "\$DMG_FILENAME" | sed -E 's/^FortiClientVPN_([0-9.]+)_OnlineInstaller\\.dmg\$/\\1/')
if [ "\$TARGET_VERSION" = "\$DMG_FILENAME" ] || [ -z "\$TARGET_VERSION" ]; then
    log "[ERROR] Could not extract version from filename: \$DMG_FILENAME"
    log "[ERROR] Expected pattern: FortiClientVPN_VERSION_OnlineInstaller.dmg"
    exit 1
fi

log "Effective URL:  \$EFFECTIVE_URL"
log "DMG filename:   \$DMG_FILENAME"
log "Target version: \$TARGET_VERSION (resolved live)"

# --- 2. Check version installée ---
if [ -d "\$APP_PATH" ]; then
    INSTALLED_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: \$INSTALLED_VERSION"
    if [ "\$INSTALLED_VERSION" = "\$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from \$INSTALLED_VERSION to \$TARGET_VERSION..."
else
    log "FortiClient not installed, performing fresh install..."
fi

# --- 3. Quit FortiClient s'il tourne ---
if pgrep -x "FortiClient" > /dev/null; then
    log "FortiClient is running — quitting gracefully..."
    osascript -e 'tell application "FortiClient" to quit' 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "FortiClient" > /dev/null || break
        sleep 2
    done
    if pgrep -x "FortiClient" > /dev/null; then
        log "[WARN] FortiClient did not quit gracefully — force killing"
        pkill -9 -x "FortiClient" 2>/dev/null || true
        sleep 2
    fi
fi

# --- 4. Télécharger l'online installer DMG ---
# On utilise \$EFFECTIVE_URL directement plutôt que \$DOWNLOAD_URL pour éviter
# une 2e résolution de redirect.
log "Downloading online installer..."
if ! curl -sSL --fail --max-time 600 "\$EFFECTIVE_URL" -o "\$ONLINE_DMG"; then
    log "[ERROR] Download failed"
    exit 1
fi

ONLINE_SIZE=\$(du -h "\$ONLINE_DMG" | awk '{print \$1}')
log "Online installer downloaded: \$ONLINE_SIZE"

# --- 5. Monter l'online installer DMG ---
log "Mounting online installer DMG..."
mkdir -p "\$ONLINE_MOUNT"
if ! hdiutil attach "\$ONLINE_DMG" -mountpoint "\$ONLINE_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount online installer DMG"
    exit 1
fi

INSTALLER_BIN="\$ONLINE_MOUNT/FortiClientInstaller.app/Contents/MacOS/FortiClientInstaller"
if [ ! -x "\$INSTALLER_BIN" ]; then
    log "[ERROR] FortiClientInstaller binary not found at \$INSTALLER_BIN"
    log "DMG content:"
    ls -la "\$ONLINE_MOUNT" | tee -a "\$LOG"
    exit 1
fi

# --- 6. Lancer FortiClientInstaller (téléchargement du vrai installer ~400 Mo) ---
log "Running FortiClientInstaller (will download the full installer, may take several minutes)..."
"\$INSTALLER_BIN" 2>&1 | tee "\$INSTALLER_LOG" | tee -a "\$LOG" || {
    INSTALLER_EXIT=\$?
    log "[WARN] FortiClientInstaller exited with code \$INSTALLER_EXIT (continuing anyway, will check for DMG)"
}

# --- 7. Extraire le chemin du FortiClient.dmg depuis la sortie ---
FC_DMG=\$(grep -oE '/var/folders/[^ ]*/FortiClient\\.dmg' "\$INSTALLER_LOG" | tail -n 1)
if [ -z "\$FC_DMG" ] || [ ! -f "\$FC_DMG" ]; then
    # Fallback : chercher dans les emplacements standard fctupdate
    FC_DMG=\$(find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" 2>/dev/null | head -n 1)
fi
if [ -z "\$FC_DMG" ] || [ ! -f "\$FC_DMG" ]; then
    log "[ERROR] Could not find FortiClient.dmg downloaded by online installer"
    log "[ERROR] Installer output (last 50 lines):"
    tail -n 50 "\$INSTALLER_LOG" | tee -a "\$LOG"
    exit 1
fi
log "Found FortiClient.dmg at: \$FC_DMG"

# Démonter l'online installer (plus besoin)
hdiutil detach "\$ONLINE_MOUNT" -force -quiet 2>/dev/null || true

# --- 8. Monter le vrai FortiClient.dmg ---
log "Mounting FortiClient.dmg..."
mkdir -p "\$FC_MOUNT"
if ! hdiutil attach "\$FC_DMG" -mountpoint "\$FC_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount FortiClient.dmg"
    exit 1
fi

# --- 9. Trouver et installer Install.mpkg ---
INSTALL_MPKG=\$(find "\$FC_MOUNT" -maxdepth 2 \\( -name "*.mpkg" -o -name "*.pkg" \\) 2>/dev/null | head -n 1)
if [ -z "\$INSTALL_MPKG" ] || [ ! -e "\$INSTALL_MPKG" ]; then
    log "[ERROR] No .mpkg/.pkg found in FortiClient.dmg"
    log "DMG content:"
    ls -la "\$FC_MOUNT" | tee -a "\$LOG"
    exit 1
fi
log "Installing from: \$INSTALL_MPKG"

if ! installer -pkg "\$INSTALL_MPKG" -target / >> "\$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- 10. Vérification post-install ---
if [ -d "\$APP_PATH" ]; then
    NEW_VERSION=\$(defaults read "\$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: FortiClient \$NEW_VERSION"
else
    log "[WARN] \$APP_PATH not found after install"
fi

log "=== FortiClient install/update successful ==="
exit 0
EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $INSTALL_SCRIPT${NC}"

cat > "$UNINSTALL_SCRIPT" << EOF
#!/bin/bash
# Uninstall script FortiClient VPN
# Suppression complète de tous les composants Fortinet macOS.
set -o pipefail
LOG="/var/log/forticlient_uninstall.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
log "=== FortiClient uninstall started ==="

# Détection de l'utilisateur (robuste sous fleetd)
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="\${SUDO_USER:-\${CONSOLE_USER:-\${USER:-root}}}"
log "Running as REAL_USER=\$REAL_USER (CONSOLE_USER=\$CONSOLE_USER)"

# --- 1. Quit / kill des processus FortiClient ---
ProgramList=("FortiClient" "FortiTray" "FortiClientAgent" "FortiClientNetworkAccessControl" "fctclient" "FortiSSLVPNXdaemon")
for p in "\${ProgramList[@]}"; do
    PIDS=\$(pgrep -f "\$p" 2>/dev/null || true)
    for pid in \$PIDS; do
        log "  kill \$p (\$pid)"
        kill -9 "\$pid" 2>/dev/null || true
    done
done
sleep 1

# --- 2. Unload des LaunchAgents Fortinet ---
for a in /Library/LaunchAgents/com.fortinet.*.plist; do
    [ -e "\$a" ] || continue
    log "  unload agent \$a"
    if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/\$CONSOLE_UID" "\$a" 2>/dev/null \\
            || launchctl asuser "\$CONSOLE_UID" launchctl unload "\$a" 2>/dev/null \\
            || true
    fi
done

# --- 3. Unload des LaunchDaemons Fortinet ---
for d in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "\$d" ] || continue
    log "  unload daemon \$d"
    launchctl bootout system "\$d" 2>/dev/null \\
        || launchctl unload "\$d" 2>/dev/null \\
        || true
done
sleep 1

# --- 4. Suppression des fichiers système ---
FilesToRemove=(
    /Applications/FortiClient.app
    /Applications/FortiClientUninstaller.app
    /Applications/FortiClientUpdate.app
    "/Library/Application Support/Fortinet"
    "/Library/Application Support/FortiClient"
    /Library/Frameworks/FortiVPN.framework
    /Library/Frameworks/FortiSSLVPNX.framework
    /Library/Frameworks/FortiSSLVPNXLib.framework
    /Library/PrivilegedHelperTools/com.fortinet.forticlient.fctclient
    /Library/PrivilegedHelperTools/com.fortinet.forticlient.uninstall_helper
    /Library/Preferences/com.fortinet.forticlient.plist
    /Library/Preferences/com.fortinet.forticlient.fortishield.plist
)
for f in "\${FilesToRemove[@]}"; do
    if [ -e "\$f" ] || [ -L "\$f" ]; then
        log "  rm \$f"
        rm -rf "\$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout fichier Fortinet restant
log "Sweeping leftover Fortinet files..."
find /Library/LaunchAgents -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/Preferences -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true

# --- 5. Cleanup ~/Library de tous les utilisateurs ---
for userdir in /Users/*; do
    [ -d "\$userdir" ] || continue
    [ "\$(basename "\$userdir")" = "Shared" ] && continue
    find "\$userdir/Library/Preferences" -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
    find "\$userdir/Library/Caches" -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
    for path in \\
        "\$userdir/Library/Application Support/Fortinet" \\
        "\$userdir/Library/Application Support/FortiClient" \\
        "\$userdir/Library/Logs/FortiClient"
    do
        if [ -e "\$path" ] || [ -L "\$path" ]; then
            log "  rm \$path"
            rm -rf "\$path" 2>/dev/null || true
        fi
    done
done

# --- 6. Forget pkg receipts ---
FortiPkgs=\$(pkgutil --pkgs | grep -iE "fortinet|forticlient" || true)
if [ -n "\$FortiPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget \$pkg"
        pkgutil --forget "\$pkg" 2>/dev/null || true
    done <<< "\$FortiPkgs"
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

log "=== FortiClient uninstall finished ==="
exit 0
EOF
chmod +x "$UNINSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $UNINSTALL_SCRIPT${NC}"
echo ""

# --- Étape 5 : Update YAML ---
echo -e "${BLUE}[5/5] Updating forticlient.yml...${NC}"

mkdir -p "$(dirname "$YAML_FILE")"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  icon:
    path: ../../all/icon/forticlient.png
  install_script:
    path: ./install_forticlient.sh
  uninstall_script:
    path: ./uninstall_forticlient.sh
EOF

echo -e "${GREEN}  ✓ Updated: $YAML_FILE${NC}"
echo ""

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$LATEST_VERSION"
        echo "filename=$DMG_FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

# --- Récap ---
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  DMG filename     : $DMG_FILENAME (build-time snapshot)"
echo "  PKG version      : $LATEST_VERSION (stub PKG, traçabilité)"
echo "  PKG identifier   : $PKG_IDENTIFIER (matches app bundle ID for Fleet)"
echo "  PKG path         : $OUTPUT_PKG"
echo "  PKG size         : $PKG_SIZE"
echo "  SHA256           : $PKG_HASH"
echo "  Install script   : $INSTALL_SCRIPT"
echo "  Uninstall script : $UNINSTALL_SCRIPT"
echo ""
echo "  Note : la version cible (TARGET_VERSION) est résolue DYNAMIQUEMENT"
echo "  à chaque exécution du script sur le Mac client, donc pas besoin de"
echo "  rebuilder le PKG à chaque release Fortinet."