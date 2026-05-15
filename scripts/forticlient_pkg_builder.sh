#!/bin/bash
# Build le PKG stub FortiClient.
# Le PKG est versionné dans Git, URL fixe via raw.githubusercontent.com.
#
# Particularité FortiClient : double étape de téléchargement, GUI bloquante.
#   1. On télécharge le "online installer" (~5 Mo, FortiClientVPN_x.y.z.dmg)
#   2. On le monte, on lance FortiClientInstaller.app/Contents/MacOS/FortiClientInstaller
#      EN ARRIÈRE-PLAN (ne se termine jamais tout seul : attend le clic "Install")
#   3. On poll /var/folders pour détecter l'apparition de FortiClient.dmg
#      ET on attend que sa taille soit stable (download terminé)
#   4. On valide l'intégrité du DMG avec hdiutil imageinfo
#   5. On kill le process GUI, on démonte l'online installer
#   6. On monte FortiClient.dmg, on lance installer -pkg Install.mpkg
#   7. On efface FortiClient.dmg + le dossier fctupdate/ (économise ~400 Mo)
#
# Bonus : si lib/unassigned/conf/vpn.plist existe, il est embarqué directement
# dans le payload du PKG stub. Il sera posé par installer(8) à l'emplacement
# /Library/Application Support/Fortinet/FortiClient/conf/vpn.plist AVANT
# l'install Fortinet. Le script d'install fait ensuite une sauvegarde du fichier
# en mémoire (TEMP_DIR), lance l'install Fortinet, puis restaure le vpn.plist
# si Fortinet l'a écrasé (et redémarre les agents pour qu'ils le relisent).

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

PKG_URL="https://raw.githubusercontent.com/${REPO}/main/lib/unassigned/download/forticlient.pkg"

EXPECTED_BUNDLE_ID="com.fortinet.FortiClient"
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
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] FortiClient stub PKG installed (no-op)" >> /var/log/forticlient_install.log
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ Stub postinstall created${NC}"
echo ""

# --- Étape 2.5 : Inclusion de la config VPN partagée dans le payload du PKG ---
# Si lib/unassigned/conf/vpn.plist existe dans le repo, on le place dans
# $EMPTY_PAYLOAD_ROOT à son chemin de destination final. pkgbuild l'embarquera
# automatiquement dans le PKG stub. Quand Fleet exécutera ce PKG sur les Macs,
# installer(8) posera le fichier à /Library/Application Support/Fortinet/
# FortiClient/conf/vpn.plist en root:wheel 0644.
VPN_PLIST_SOURCE="$REPO_ROOT/lib/unassigned/conf/vpn.plist"
VPN_PLIST_TARGET_RELATIVE="Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

echo -e "${BLUE}[2.5/5] Embedding shared VPN config into PKG payload...${NC}"
mkdir -p "$EMPTY_PAYLOAD_ROOT"
if [ -f "$VPN_PLIST_SOURCE" ]; then
    if ! plutil -lint "$VPN_PLIST_SOURCE" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] $VPN_PLIST_SOURCE n'est pas un plist valide${NC}"
        plutil -lint "$VPN_PLIST_SOURCE"
        exit 1
    fi
    VPN_TARGET_DIR="$EMPTY_PAYLOAD_ROOT/$(dirname "$VPN_PLIST_TARGET_RELATIVE")"
    mkdir -p "$VPN_TARGET_DIR"
    cp "$VPN_PLIST_SOURCE" "$VPN_TARGET_DIR/vpn.plist"
    chmod 0644 "$VPN_TARGET_DIR/vpn.plist"
    VPN_SRC_SIZE=$(wc -c < "$VPN_PLIST_SOURCE" | tr -d ' ')
    echo -e "${GREEN}  ✓ vpn.plist embedded: $VPN_SRC_SIZE bytes${NC}"
    echo -e "${GREEN}  ✓ Target on Mac:     /$VPN_PLIST_TARGET_RELATIVE${NC}"
else
    echo -e "${YELLOW}  ⚠ $VPN_PLIST_SOURCE introuvable — le PKG ne contiendra PAS de config VPN${NC}"
    echo -e "${YELLOW}    Pour pousser une config partagée, place ton vpn.plist à cet emplacement.${NC}"
fi
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
    <title>FortiClient 7</title>
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
echo -e "${BLUE}[4/5] Generating Fleet install/uninstall scripts...${NC}"

mkdir -p "$SOFTWARE_DIR"

cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash
# Install script FortiClient VPN — appelé par Fleet (PAS imbriqué dans un autre installer).
#
# Built on $(date '+%Y-%m-%d %H:%M:%S') (build-time snapshot: $LATEST_VERSION)
# Expected Bundle ID: $EXPECTED_BUNDLE_ID

set -uo pipefail

DOWNLOAD_URL="$DOWNLOAD_URL"
APP_PATH="$APP_PATH"
TEMP_DIR=\$(mktemp -d)
ONLINE_DMG="\$TEMP_DIR/FortiClientVPN_OnlineInstaller.dmg"
ONLINE_MOUNT="\$TEMP_DIR/online_mount"
FC_MOUNT="\$TEMP_DIR/fc_mount"
LOG="/var/log/forticlient_install.log"

INSTALLER_PID=""
FINAL_DMG_PATH=""

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }

cleanup() {
    if [ -n "\$INSTALLER_PID" ] && kill -0 "\$INSTALLER_PID" 2>/dev/null; then
        kill -9 "\$INSTALLER_PID" 2>/dev/null || true
    fi
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

# --- 4. Nettoyage préventif des FortiClient.dmg orphelins (>1h) ---
log "Cleaning up stale fctupdate caches (>1h old)..."
find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" -mmin +60 -delete 2>/dev/null || true
find /var/folders -type d -name "fctupdate" -mmin +60 -empty -delete 2>/dev/null || true

# --- 5. Télécharger l'online installer DMG ---
log "Downloading online installer..."
if ! curl -sSL --fail --max-time 600 "\$EFFECTIVE_URL" -o "\$ONLINE_DMG"; then
    log "[ERROR] Download failed"
    exit 1
fi

ONLINE_SIZE=\$(du -h "\$ONLINE_DMG" | awk '{print \$1}')
log "Online installer downloaded: \$ONLINE_SIZE"

# --- 6. Monter l'online installer DMG ---
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

# --- 7. Lancer FortiClientInstaller EN ARRIÈRE-PLAN ---
log "Launching FortiClientInstaller in background..."
"\$INSTALLER_BIN" > /dev/null 2>&1 &
INSTALLER_PID=\$!
log "  Background PID: \$INSTALLER_PID"

# --- 8. Polling : attendre que FortiClient.dmg soit téléchargé ET COMPLET ---
#
# IMPORTANT : FortiClientInstaller crée le fichier dès le début du download et
# le remplit progressivement. On ne peut PAS se contenter de détecter sa simple
# présence — un essai de mount sur un DMG partiel échoue avec :
#   "Failed to mount FortiClient.dmg"
#
# Deux niveaux de sécurité :
#   a) Stabilité de taille : 2 mesures consécutives à 5s d'intervalle identiques
#   b) Validation hdiutil imageinfo : lit la structure interne, échoue si tronqué
log "Waiting for FortiClient.dmg to be fully downloaded..."

WAITED=0
MAX_WAIT=900   # 15 min de timeout de sécurité
LOG_INTERVAL=30
MIN_SIZE=100000000   # 100 Mo minimum (le DMG complet fait ~400 Mo)

while [ -z "\$FINAL_DMG_PATH" ]; do
    # Cherche un FortiClient.dmg récent
    CANDIDATE=\$(find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" -mmin -30 2>/dev/null | head -n 1)

    if [ -n "\$CANDIDATE" ] && [ -f "\$CANDIDATE" ]; then
        # Mesure 1 de la taille
        SIZE1=\$(stat -f%z "\$CANDIDATE" 2>/dev/null || echo 0)
        sleep 5
        # Mesure 2 après 5s
        SIZE2=\$(stat -f%z "\$CANDIDATE" 2>/dev/null || echo 0)

        if [ "\$SIZE1" = "\$SIZE2" ] && [ "\$SIZE1" -ge "\$MIN_SIZE" ]; then
            # Taille stable et minimum atteint → on valide l'intégrité du DMG
            SIZE_MB=\$((SIZE1 / 1024 / 1024))
            log "  Size stable at \${SIZE_MB} MB — verifying DMG integrity..."

            if hdiutil imageinfo "\$CANDIDATE" >/dev/null 2>&1; then
                # DMG complet et structurellement valide
                FINAL_DMG_PATH="\$CANDIDATE"
                log "  ✓ DMG integrity OK"
                break
            else
                log "  ⚠ DMG not yet valid (still being written?) — continuing to wait"
            fi
        else
            # Taille encore en évolution → download en cours
            SIZE_MB=\$((SIZE2 / 1024 / 1024))
            log "  Download in progress: \${SIZE_MB} MB (\$SIZE1 → \$SIZE2 bytes)"
        fi
        WAITED=\$((WAITED + 5))
    else
        # Pas encore de fichier détecté
        sleep 2
        WAITED=\$((WAITED + 2))
        if [ \$((WAITED % LOG_INTERVAL)) -eq 0 ]; then
            log "  Still waiting for file to appear... (\${WAITED}s elapsed, max \${MAX_WAIT}s)"
        fi
    fi

    # Sécurité : l'installer a-t-il crashé ?
    if ! kill -0 "\$INSTALLER_PID" 2>/dev/null; then
        log "[ERROR] FortiClientInstaller a quitté avant d'avoir produit un DMG complet"
        exit 1
    fi

    # Timeout global
    if [ "\$WAITED" -ge "\$MAX_WAIT" ]; then
        log "[ERROR] Timeout : FortiClient.dmg pas complet après \${MAX_WAIT}s"
        exit 1
    fi
done

FINAL_SIZE=\$(du -h "\$FINAL_DMG_PATH" | awk '{print \$1}')
log "FortiClient.dmg ready: \$FINAL_DMG_PATH (\$FINAL_SIZE, \${WAITED}s elapsed)"

# --- 9. Tuer l'installer GUI (court-circuite le bouton "Install") ---
log "Killing FortiClientInstaller GUI (PID \$INSTALLER_PID)..."
kill -9 "\$INSTALLER_PID" 2>/dev/null || true
INSTALLER_PID=""

# --- 10. Démonter l'online installer ---
hdiutil detach "\$ONLINE_MOUNT" -force -quiet 2>/dev/null || true
log "Online installer unmounted."

# --- 11. Monter le vrai FortiClient.dmg ---
log "Mounting FortiClient.dmg..."
mkdir -p "\$FC_MOUNT"
if ! hdiutil attach "\$FINAL_DMG_PATH" -mountpoint "\$FC_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount FortiClient.dmg"
    exit 1
fi

# --- 12. Trouver et installer Install.mpkg ---
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
installer -pkg "\$INSTALLER_PATH" -target /

        VPN_CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
        VPN_CONSOLE_UID=\$(id -u "\$VPN_CONSOLE_USER" 2>/dev/null || echo "")

        # LaunchDaemons (system domain)
        for daemon in /Library/LaunchDaemons/com.fortinet.*.plist; do
            [ -e "\$daemon" ] || continue
            launchctl bootout system "\$daemon" 2>/dev/null || true
            launchctl bootstrap system "\$daemon" 2>/dev/null \\
                || launchctl load "\$daemon" 2>/dev/null \\
                || true
        done

        # LaunchAgents (session GUI utilisateur)
        if [ -n "\$VPN_CONSOLE_UID" ] && [ "\$VPN_CONSOLE_UID" != "0" ]; then
            for agent in /Library/LaunchAgents/com.fortinet.*.plist; do
                [ -e "\$agent" ] || continue
                launchctl bootout "gui/\$VPN_CONSOLE_UID" "\$agent" 2>/dev/null || true
                launchctl bootstrap "gui/\$VPN_CONSOLE_UID" "\$agent" 2>/dev/null \\
                    || launchctl asuser "\$VPN_CONSOLE_UID" launchctl load "\$agent" 2>/dev/null \\
                    || true
            done
        else
            log "  [WARN] No user in GUI — agents will load with restored config at next login"
        fi
    else
        log "VPN config preserved by Fortinet install — no restoration needed"
    fi
fi

# --- 13. Démonter FortiClient.dmg avant cleanup ---
hdiutil detach "\$FC_MOUNT" -force -quiet 2>/dev/null || true
log "FortiClient.dmg unmounted."

# --- 14. Cleanup du FortiClient.dmg téléchargé (~400 Mo) ---
log "Cleaning up downloaded FortiClient.dmg cache..."
if [ -n "\$FINAL_DMG_PATH" ] && [ -f "\$FINAL_DMG_PATH" ]; then
    rm -f "\$FINAL_DMG_PATH" 2>/dev/null || true
    log "  Removed \$FINAL_DMG_PATH"
    FCTUPDATE_DIR=\$(dirname "\$FINAL_DMG_PATH")
    if [ -d "\$FCTUPDATE_DIR" ]; then
        if rmdir "\$FCTUPDATE_DIR" 2>/dev/null; then
            log "  Removed empty \$FCTUPDATE_DIR"
        else
            log "  Kept \$FCTUPDATE_DIR (not empty)"
        fi
    fi
fi

# --- 15. Vérification post-install ---
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
set -o pipefail
LOG="/var/log/forticlient_uninstall.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
log "=== FortiClient uninstall started ==="

CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="\${SUDO_USER:-\${CONSOLE_USER:-\${USER:-root}}}"
log "Running as REAL_USER=\$REAL_USER (CONSOLE_USER=\$CONSOLE_USER)"

ProgramList=("FortiClient" "FortiTray" "FortiClientAgent" "FortiClientNetworkAccessControl" "fctclient" "FortiSSLVPNXdaemon" "FortiClientInstaller")
for p in "\${ProgramList[@]}"; do
    PIDS=\$(pgrep -f "\$p" 2>/dev/null || true)
    for pid in \$PIDS; do
        log "  kill \$p (\$pid)"
        kill -9 "\$pid" 2>/dev/null || true
    done
done
sleep 1

for a in /Library/LaunchAgents/com.fortinet.*.plist; do
    [ -e "\$a" ] || continue
    log "  unload agent \$a"
    if [ -n "\$CONSOLE_UID" ] && [ "\$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/\$CONSOLE_UID" "\$a" 2>/dev/null \\
            || launchctl asuser "\$CONSOLE_UID" launchctl unload "\$a" 2>/dev/null \\
            || true
    fi
done

for d in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "\$d" ] || continue
    log "  unload daemon \$d"
    launchctl bootout system "\$d" 2>/dev/null \\
        || launchctl unload "\$d" 2>/dev/null \\
        || true
done
sleep 1

# --- Désactivation des System Extensions Fortinet ---
# Tant que la NetworkExtension VPN est active, macOS refuse de supprimer l'app
# qui la fournit (FortiClient.app). On la désactive avant le rm.
log "Deactivating Fortinet System Extensions..."
SYSEXT_LIST=\$(systemextensionsctl list 2>/dev/null | grep -i "fortinet\\|forticlient" || true)
if [ -n "\$SYSEXT_LIST" ]; then
    log "  Found system extensions to uninstall:"
    echo "\$SYSEXT_LIST" | tee -a "\$LOG"
    # Le team ID Fortinet est AH4XFXJ7DK pour toutes les extensions
    for ext_id in \$(echo "\$SYSEXT_LIST" | awk '{for(i=1;i<=NF;i++) if(\$i ~ /^com\\.fortinet/) print \$i}' | sort -u); do
        log "  uninstall \$ext_id"
        systemextensionsctl uninstall AH4XFXJ7DK "\$ext_id" 2>>"\$LOG" || true
    done
    sleep 2
else
    log "  No Fortinet system extensions found"
fi

# Helper de suppression robuste — gère les obstacles fréquents qui font échouer rm -rf :
#   - xattr com.apple.macl (protection TCC)
#   - flags système (schg, uchg)
#   - permissions restrictives
#   - ownership non-root (install drag-and-drop)
# Si rm échoue malgré tout, fallback mv→/tmp puis rm.
robust_remove() {
    local target="\$1"
    [ -e "\$target" ] || [ -L "\$target" ] || return 0

    # 1. Effacer toutes les xattrs (notamment com.apple.macl posée par TCC)
    xattr -cr "\$target" 2>/dev/null || true
    # 2. Effacer les flags système d'immutabilité (schg, uchg, appnd)
    chflags -R noschg,nouchg,noappnd "\$target" 2>/dev/null || true
    # 3. S'assurer que root a les droits d'écriture
    chmod -R u+w "\$target" 2>/dev/null || true
    # 4. Reprendre l'ownership si l'app a été installée drag-and-drop
    chown -R root:wheel "\$target" 2>/dev/null || true

    # 5. Tentative directe
    if rm -rf "\$target" 2>>"\$LOG"; then
        log "  ✓ rm \$target"
        return 0
    fi

    # 6. Fallback : mv vers /tmp puis rm depuis là (contourne certaines protections
    #    quand le parent dir bloque la suppression directe)
    local trash="/tmp/.forticlient_trash_\$\$_\$(date +%s)"
    if mv "\$target" "\$trash" 2>>"\$LOG"; then
        rm -rf "\$trash" 2>/dev/null || true
        log "  ✓ rm (via mv→/tmp) \$target"
        return 0
    fi

    log "  ✗ Could not remove \$target — kept on disk (Operation not permitted?)"
    return 1
}

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
    robust_remove "\$f"
done

log "Sweeping leftover Fortinet files..."
find /Library/LaunchAgents -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true
find /Library/Preferences -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \\; 2>/dev/null || true

log "Cleaning up online installer cache (fctupdate)..."
find /var/folders -type d -name "fctupdate" -exec rm -rf {} \\; 2>/dev/null || true

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

FortiPkgs=\$(pkgutil --pkgs | grep -iE "fortinet|forticlient" || true)
if [ -n "\$FortiPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget \$pkg"
        pkgutil --forget "\$pkg" 2>/dev/null || true
    done <<< "\$FortiPkgs"
fi
pkgutil --forget "$PKG_IDENTIFIER" 2>/dev/null || true

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

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$LATEST_VERSION"
        echo "filename=$DMG_FILENAME"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
    } >> "$GITHUB_OUTPUT"
fi

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
if [ -f "$VPN_PLIST_SOURCE" ]; then
    echo "  VPN config       : embedded in PKG payload ($VPN_SRC_SIZE bytes)"
else
    echo "  VPN config       : NOT included (lib/unassigned/conf/vpn.plist absent)"
fi
echo ""
echo "  Polling install  : taille stable (2 mesures à 5s) + min 100 MB"
echo "                     + validation hdiutil imageinfo"
echo "  Cleanup initial  : fctupdate caches >1h old (orphelins de runs ratés)"
echo "  Cleanup final    : suppression du FortiClient.dmg après installer -pkg OK"
echo "  Timeout sécurité : 15 min (modifiable via MAX_WAIT)"