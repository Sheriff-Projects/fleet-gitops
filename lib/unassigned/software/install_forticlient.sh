#!/bin/bash
# Install script FortiClient VPN — appelé par Fleet (PAS imbriqué dans un autre installer).
#
# Built on 2026-05-14 14:20:38 (build-time snapshot: 7.4.3.4323)
# Expected Bundle ID: com.fortinet.FortiClient
#
# La version cible est résolue DYNAMIQUEMENT à chaque exécution via le redirect
# Fortinet, donc pas besoin de rebuilder le PKG à chaque release Fortinet.
#
# Workflow Fortinet en deux étapes :
#   1. Résoudre l'URL effective (redirect) → version + filename
#   2. Télécharger l'online installer DMG (~5 Mo)
#   3. Le monter, lancer FortiClientInstaller EN ARRIÈRE-PLAN
#      (sa GUI ne se termine jamais toute seule — elle attend le clic "Install")
#   4. Poller /var/folders pour détecter l'apparition du FortiClient.dmg
#   5. Tuer le process GUI, démonter l'online DMG
#   6. Monter FortiClient.dmg, lancer installer -pkg
#   7. Nettoyer le FortiClient.dmg téléchargé (~400 Mo) pour pas saturer le disque

set -uo pipefail

DOWNLOAD_URL="https://links.fortinet.com/forticlient/mac/vpnagent"
APP_PATH="/Applications/FortiClient.app"
TEMP_DIR=$(mktemp -d)
ONLINE_DMG="$TEMP_DIR/FortiClientVPN_OnlineInstaller.dmg"
ONLINE_MOUNT="$TEMP_DIR/online_mount"
FC_MOUNT="$TEMP_DIR/fc_mount"
LOG="/var/log/forticlient_install.log"

INSTALLER_PID=""
FINAL_DMG_PATH=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

cleanup() {
    if [ -n "$INSTALLER_PID" ] && kill -0 "$INSTALLER_PID" 2>/dev/null; then
        kill -9 "$INSTALLER_PID" 2>/dev/null || true
    fi
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

# --- 4. Nettoyage préventif des FortiClient.dmg orphelins d'anciens runs ---
# Si un précédent run a échoué avant le cleanup final, des dossiers fctupdate/
# peuvent traîner. On supprime ceux modifiés il y a plus d'1 heure pour éviter
# de réutiliser un DMG potentiellement corrompu.
log "Cleaning up stale fctupdate caches (>1h old)..."
find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" -mmin +60 -delete 2>/dev/null || true
find /var/folders -type d -name "fctupdate" -mmin +60 -empty -delete 2>/dev/null || true

# --- 5. Télécharger l'online installer DMG ---
log "Downloading online installer..."
if ! curl -sSL --fail --max-time 600 "$EFFECTIVE_URL" -o "$ONLINE_DMG"; then
    log "[ERROR] Download failed"
    exit 1
fi

ONLINE_SIZE=$(du -h "$ONLINE_DMG" | awk '{print $1}')
log "Online installer downloaded: $ONLINE_SIZE"

# --- 6. Monter l'online installer DMG ---
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

# --- 7. Lancer FortiClientInstaller EN ARRIÈRE-PLAN ---
log "Launching FortiClientInstaller in background..."
"$INSTALLER_BIN" > /dev/null 2>&1 &
INSTALLER_PID=$!
log "  Background PID: $INSTALLER_PID"

# --- 8. Polling : attendre l'apparition du FortiClient.dmg téléchargé ---
# On filtre sur les fichiers récents (-mmin -30) pour ignorer d'éventuels
# DMG orphelins qu'on n'aurait pas réussi à nettoyer à l'étape 4.
log "Waiting for FortiClient.dmg to appear (download can take several minutes)..."
WAITED=0
MAX_WAIT=900   # 15 min de timeout de sécurité
LOG_INTERVAL=30  # On logge la progression toutes les 30s

while [ -z "$FINAL_DMG_PATH" ]; do
    FINAL_DMG_PATH=$(find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" -mmin -30 2>/dev/null | head -n 1)
    if [ -n "$FINAL_DMG_PATH" ] && [ -f "$FINAL_DMG_PATH" ]; then
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))

    if [ $((WAITED % LOG_INTERVAL)) -eq 0 ]; then
        log "  Still waiting... (${WAITED}s elapsed, max ${MAX_WAIT}s)"
    fi

    if ! kill -0 "$INSTALLER_PID" 2>/dev/null; then
        log "[ERROR] FortiClientInstaller a quitté avant d'avoir produit le DMG"
        exit 1
    fi

    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        log "[ERROR] Timeout : FortiClient.dmg pas apparu après ${MAX_WAIT}s"
        exit 1
    fi
done

log "FortiClient.dmg detected: $FINAL_DMG_PATH (${WAITED}s elapsed)"
FC_DMG_SIZE=$(du -h "$FINAL_DMG_PATH" | awk '{print $1}')
log "Size: $FC_DMG_SIZE"

# --- 9. Tuer l'installer GUI (court-circuite le bouton "Install") ---
log "Killing FortiClientInstaller GUI (PID $INSTALLER_PID)..."
kill -9 "$INSTALLER_PID" 2>/dev/null || true
INSTALLER_PID=""

# --- 10. Démonter l'online installer ---
hdiutil detach "$ONLINE_MOUNT" -force -quiet 2>/dev/null || true
log "Online installer unmounted."

# --- 11. Monter le vrai FortiClient.dmg ---
log "Mounting FortiClient.dmg..."
mkdir -p "$FC_MOUNT"
if ! hdiutil attach "$FINAL_DMG_PATH" -mountpoint "$FC_MOUNT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount FortiClient.dmg"
    exit 1
fi

# --- 12. Trouver et installer Install.mpkg ---
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

# --- 13. Démonter FortiClient.dmg avant cleanup ---
hdiutil detach "$FC_MOUNT" -force -quiet 2>/dev/null || true
log "FortiClient.dmg unmounted."

# --- 14. Cleanup du FortiClient.dmg téléchargé (~400 Mo) ---
# On fait ce nettoyage seulement APRÈS un installer -pkg réussi.
# En cas d'erreur plus haut, on garde le fichier pour debug.
log "Cleaning up downloaded FortiClient.dmg cache..."
if [ -n "$FINAL_DMG_PATH" ] && [ -f "$FINAL_DMG_PATH" ]; then
    rm -f "$FINAL_DMG_PATH" 2>/dev/null || true
    log "  Removed $FINAL_DMG_PATH"
    # rmdir = supprime le dossier fctupdate seulement s'il est vide (protection
    # au cas où Fortinet y aurait laissé d'autres fichiers)
    FCTUPDATE_DIR=$(dirname "$FINAL_DMG_PATH")
    if [ -d "$FCTUPDATE_DIR" ]; then
        if rmdir "$FCTUPDATE_DIR" 2>/dev/null; then
            log "  Removed empty $FCTUPDATE_DIR"
        else
            log "  Kept $FCTUPDATE_DIR (not empty)"
        fi
    fi
fi

# --- 15. Vérification post-install ---
if [ -d "$APP_PATH" ]; then
    NEW_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: FortiClient $NEW_VERSION"
else
    log "[WARN] $APP_PATH not found after install"
fi

log "=== FortiClient install/update successful ==="
exit 0
