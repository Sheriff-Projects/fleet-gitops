#!/bin/bash
# Install script FortiClient VPN — appelé par Fleet (PAS imbriqué dans un autre installer).
#
# Built on 2026-05-14 13:04:59 (build-time snapshot: 7.4.3.4323)
# Expected Bundle ID: com.fortinet.FortiClient
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

DOWNLOAD_URL="https://links.fortinet.com/forticlient/mac/vpnagent"
APP_PATH="/Applications/FortiClient.app"
TEMP_DIR=$(mktemp -d)
ONLINE_DMG="$TEMP_DIR/FortiClientVPN_OnlineInstaller.dmg"
ONLINE_MOUNT="$TEMP_DIR/online_mount"
FC_MOUNT="$TEMP_DIR/fc_mount"
INSTALLER_LOG="$TEMP_DIR/forticlient_installer.log"
LOG="/var/log/forticlient_install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

cleanup() {
    hdiutil detach "$FC_MOUNT" -force -quiet 2>/dev/null || true
    hdiutil detach "$ONLINE_MOUNT" -force -quiet 2>/dev/null || true
    [ -d "/Volumes/FortiClientInstaller" ] && hdiutil detach "/Volumes/FortiClientInstaller" -force -quiet 2>/dev/null || true
    [ -d "/Volumes/FortiClient" ] && hdiutil detach "/Volumes/FortiClient" -force -quiet 2>/dev/null || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log "=== FortiClient install/update started (Fleet script) ==="

# --- 1. Résolution dynamique de la version cible via redirect Fortinet ---
log "Resolving live version from Fortinet redirect..."
EFFECTIVE_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "$DOWNLOAD_URL" || echo "")
if [ -z "$EFFECTIVE_URL" ] || [ "$EFFECTIVE_URL" = "$DOWNLOAD_URL" ]; then
    log "[ERROR] No redirect from Fortinet — endpoint may have changed or network is down"
    log "[ERROR] DOWNLOAD_URL=$DOWNLOAD_URL"
    log "[ERROR] EFFECTIVE_URL=$EFFECTIVE_URL"
    exit 1
fi

DMG_FILENAME=$(echo "$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
# Format : FortiClientVPN_7.4.3.4323_OnlineInstaller.dmg → 7.4.3.4323
TARGET_VERSION=$(echo "$DMG_FILENAME" | sed -E 's/^FortiClientVPN_([0-9.]+)_OnlineInstaller\.dmg$/\1/')
if [ "$TARGET_VERSION" = "$DMG_FILENAME" ] || [ -z "$TARGET_VERSION" ]; then
    log "[ERROR] Could not extract version from filename: $DMG_FILENAME"
    log "[ERROR] Expected pattern: FortiClientVPN_VERSION_OnlineInstaller.dmg"
    exit 1
fi

log "Effective URL:  $EFFECTIVE_URL"
log "DMG filename:   $DMG_FILENAME"
log "Target version: $TARGET_VERSION (resolved live)"

# --- 2. Check version installée ---
if [ -d "$APP_PATH" ]; then
    INSTALLED_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: $INSTALLED_VERSION"
    if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from $INSTALLED_VERSION to $TARGET_VERSION..."
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
# On utilise $EFFECTIVE_URL directement plutôt que $DOWNLOAD_URL pour éviter
# une 2e résolution de redirect.
log "Downloading online installer..."
if ! curl -sSL --fail --max-time 600 "$EFFECTIVE_URL" -o "$ONLINE_DMG"; then
    log "[ERROR] Download failed"
    exit 1
fi

ONLINE_SIZE=$(du -h "$ONLINE_DMG" | awk '{print $1}')
log "Online installer downloaded: $ONLINE_SIZE"

# --- 5. Monter l'online installer DMG ---
log "Mounting online installer DMG..."
mkdir -p "$ONLINE_MOUNT"
if ! hdiutil attach "$ONLINE_DMG" -mountpoint "$ONLINE_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount online installer DMG"
    exit 1
fi

INSTALLER_BIN="$ONLINE_MOUNT/FortiClientInstaller.app/Contents/MacOS/FortiClientInstaller"
if [ ! -x "$INSTALLER_BIN" ]; then
    log "[ERROR] FortiClientInstaller binary not found at $INSTALLER_BIN"
    log "DMG content:"
    ls -la "$ONLINE_MOUNT" | tee -a "$LOG"
    exit 1
fi

# --- 6. Lancer FortiClientInstaller (téléchargement du vrai installer ~400 Mo) ---
log "Running FortiClientInstaller (will download the full installer, may take several minutes)..."
"$INSTALLER_BIN" 2>&1 | tee "$INSTALLER_LOG" | tee -a "$LOG" || {
    INSTALLER_EXIT=$?
    log "[WARN] FortiClientInstaller exited with code $INSTALLER_EXIT (continuing anyway, will check for DMG)"
}

# --- 7. Extraire le chemin du FortiClient.dmg depuis la sortie ---
FC_DMG=$(grep -oE '/var/folders/[^ ]*/FortiClient\.dmg' "$INSTALLER_LOG" | tail -n 1)
if [ -z "$FC_DMG" ] || [ ! -f "$FC_DMG" ]; then
    # Fallback : chercher dans les emplacements standard fctupdate
    FC_DMG=$(find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" 2>/dev/null | head -n 1)
fi
if [ -z "$FC_DMG" ] || [ ! -f "$FC_DMG" ]; then
    log "[ERROR] Could not find FortiClient.dmg downloaded by online installer"
    log "[ERROR] Installer output (last 50 lines):"
    tail -n 50 "$INSTALLER_LOG" | tee -a "$LOG"
    exit 1
fi
log "Found FortiClient.dmg at: $FC_DMG"

# Démonter l'online installer (plus besoin)
hdiutil detach "$ONLINE_MOUNT" -force -quiet 2>/dev/null || true

# --- 8. Monter le vrai FortiClient.dmg ---
log "Mounting FortiClient.dmg..."
mkdir -p "$FC_MOUNT"
if ! hdiutil attach "$FC_DMG" -mountpoint "$FC_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount FortiClient.dmg"
    exit 1
fi

# --- 9. Trouver et installer Install.mpkg ---
INSTALL_MPKG=$(find "$FC_MOUNT" -maxdepth 2 \( -name "*.mpkg" -o -name "*.pkg" \) 2>/dev/null | head -n 1)
if [ -z "$INSTALL_MPKG" ] || [ ! -e "$INSTALL_MPKG" ]; then
    log "[ERROR] No .mpkg/.pkg found in FortiClient.dmg"
    log "DMG content:"
    ls -la "$FC_MOUNT" | tee -a "$LOG"
    exit 1
fi
log "Installing from: $INSTALL_MPKG"

if ! installer -pkg "$INSTALL_MPKG" -target / >> "$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- 10. Vérification post-install ---
if [ -d "$APP_PATH" ]; then
    NEW_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: FortiClient $NEW_VERSION"
else
    log "[WARN] $APP_PATH not found after install"
fi

log "=== FortiClient install/update successful ==="
exit 0
