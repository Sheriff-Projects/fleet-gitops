#!/bin/bash
# Install script FortiClient VPN — appelé par Fleet (PAS imbriqué dans un autre installer).
#
# Built on 2026-05-14 23:06:34 (build-time snapshot: 7.4.3.4323)
# Expected Bundle ID: com.fortinet.FortiClient

set -uo pipefail

DOWNLOAD_URL="https://links.fortinet.com/forticlient/mac/vpnagent"
APP_PATH="/Applications/FortiClient.app"
TEMP_DIR=$(mktemp -d)
ONLINE_DMG="$TEMP_DIR/FortiClientVPN_OnlineInstaller.dmg"
ONLINE_MOUNT="$TEMP_DIR/online_mount"
FC_MOUNT="$TEMP_DIR/fc_mount"
LOG="/var/log/forticlient_install.log"

# Config VPN partagée — figée par le builder depuis lib/unassigned/conf/vpn.plist
# Vide si aucun vpn.plist n'était présent au moment du build.
VPN_PLIST_B64="PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPCFET0NUWVBFIHBsaXN0IFBVQkxJQyAiLS8vQXBwbGUvL0RURCBQTElTVCAxLjAvL0VOIiAiaHR0cDovL3d3dy5hcHBsZS5jb20vRFREcy9Qcm9wZXJ0eUxpc3QtMS4wLmR0ZCI+CjxwbGlzdCB2ZXJzaW9uPSIxLjAiPgo8ZGljdD4KCTxrZXk+QXV0b0Nvbm5lY3RPbkluc3RhbGw8L2tleT4KCTxpbnRlZ2VyPjA8L2ludGVnZXI+Cgk8a2V5PkF1dG9TdGFydFZQTjwva2V5PgoJPHN0cmluZz48L3N0cmluZz4KCTxrZXk+QXV0b1N0YXJ0VlBOT25seU9mZk5ldDwva2V5PgoJPGludGVnZXI+MDwvaW50ZWdlcj4KCTxrZXk+RE5TU2VydmljZVJlc2V0dGluZ0ludGVydmFsPC9rZXk+Cgk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJPGtleT5EaXNhYmxlQ29ubmVjdERpc2Nvbm5lY3Q8L2tleT4KCTxpbnRlZ2VyPjA8L2ludGVnZXI+Cgk8a2V5PkRpc2FsbG93UGVyc29uYWxWUE48L2tleT4KCTxpbnRlZ2VyPjA8L2ludGVnZXI+Cgk8a2V5PkR0bHNNVFU8L2tleT4KCTxpbnRlZ2VyPjExMDA8L2ludGVnZXI+Cgk8a2V5PkVuYWJsZUlQU2VjPC9rZXk+Cgk8aW50ZWdlcj4xPC9pbnRlZ2VyPgoJPGtleT5FbmFibGVTU0w8L2tleT4KCTxpbnRlZ2VyPjE8L2ludGVnZXI+Cgk8a2V5PkluaGVyaXRMb2NhbEROUzwva2V5PgoJPGludGVnZXI+MDwvaW50ZWdlcj4KCTxrZXk+SXBzZWNTaG91bGRCbG9ja0lwdjY8L2tleT4KCTxpbnRlZ2VyPjE8L2ludGVnZXI+Cgk8a2V5Pk1pbmltaXplT25Db25uZWN0PC9rZXk+Cgk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJPGtleT5QcmVmZXJEdGxzVHVubmVsPC9rZXk+Cgk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJPGtleT5Qcm9maWxlczwva2V5PgoJPGRpY3Q+CgkJPGtleT5BbWFuZGllcnMgLSBTUCBWUE48L2tleT4KCQk8ZGljdD4KCQkJPGtleT5BbGxvd0F1dG9Db25uZWN0PC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+QWxsb3dLZWVwUnVubmluZzwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PkFsbG93U2F2ZVBhc3N3b3JkPC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+QWxsb3dlZFRhZ3M8L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5BdXRoSW5mbzwva2V5PgoJCQk8c3RyaW5nPjwvc3RyaW5nPgoJCQk8a2V5PkNlcnRDTk1hdGNoVHlwZTwva2V5PgoJCQk8c3RyaW5nPjwvc3RyaW5nPgoJCQk8a2V5PkNlcnRDTlBhdHRlcm48L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5DZXJ0SXNzdWVyTWF0Y2hUeXBlPC9rZXk+CgkJCTxzdHJpbmc+PC9zdHJpbmc+CgkJCTxrZXk+Q2VydElzc3VlclBhdHRlcm48L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5Db21tZW50PC9rZXk+CgkJCTxzdHJpbmc+PC9zdHJpbmc+CgkJCTxrZXk+RGlzY2xhaW1lck1lc3NhZ2U8L2tleT4KCQkJPHN0cmluZz4kbnVsbDwvc3RyaW5nPgoJCQk8a2V5PkVtc0FsbG93QXV0b0Nvbm5lY3Q8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5FbXNBbGxvd0tlZXBSdW5uaW5nPC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+RW1zQWxsb3dTYXZlUGFzc3dvcmQ8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5FbmFibGVDdXN0b21Qb3J0PC9rZXk+CgkJCTxpbnRlZ2VyPjE8L2ludGVnZXI+CgkJCTxrZXk+R290U2V0dGluZ3NGcm9tRkdUPC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+SG9zdGNoZWNrRmFpbFdhcm5pbmc8L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5LZWVwUnVubmluZzwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PktlZXBSdW5uaW5nTWF4UmV0cnk8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5OYW1lPC9rZXk+CgkJCTxzdHJpbmc+U+KAolAgVlBOIC0gQW1hbmRpZXJzPC9zdHJpbmc+CgkJCTxrZXk+T25Db25uZWN0U2NyaXB0PC9rZXk+CgkJCTxzdHJpbmc+JG51bGw8L3N0cmluZz4KCQkJPGtleT5PbkRpc2Nvbm5lY3RTY3JpcHQ8L2tleT4KCQkJPHN0cmluZz4kbnVsbDwvc3RyaW5nPgoJCQk8a2V5PlByb2hpYml0ZWRUYWdzPC9rZXk+CgkJCTxzdHJpbmc+PC9zdHJpbmc+CgkJCTxrZXk+UHJvbXB0Rm9yQXV0aGVudGljYXRpb248L2tleT4KCQkJPGludGVnZXI+MTwvaW50ZWdlcj4KCQkJPGtleT5Qcm9tcHRGb3JDZXJ0aWZpY2F0ZTwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PlByb3h5QWRkcmVzczwva2V5PgoJCQk8c3RyaW5nPjwvc3RyaW5nPgoJCQk8a2V5PlByb3h5UGFzc3dvcmQ8L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5Qcm94eVBvcnQ8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5Qcm94eVVzZXI8L2tleT4KCQkJPHN0cmluZz48L3N0cmluZz4KCQkJPGtleT5SZWFkT25seTwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PlJlZHVuZGFudFNvcnRNZXRob2Q8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5TU09FbmFibGVkPC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+U2FtbEZRRE5Db25zaXN0ZW5jeTwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PlNhdmVQYXNzd29yZDwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PlNhdmVVc2VybmFtZTwva2V5PgoJCQk8aW50ZWdlcj4wPC9pbnRlZ2VyPgoJCQk8a2V5PlNlcnZlcjwva2V5PgoJCQk8c3RyaW5nPnNoZXJpZmYtYW1hbmRpZXIuZm9ydGlkZG5zLmNvbTwvc3RyaW5nPgoJCQk8a2V5PlNlcnZlclBvcnQ8L2tleT4KCQkJPGludGVnZXI+ODQ0MzwvaW50ZWdlcj4KCQkJPGtleT5TaG93UGFzc2NvZGU8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5Tc2xWcG5UeXBlPC9rZXk+CgkJCTxzdHJpbmc+PC9zdHJpbmc+CgkJCTxrZXk+VHJhZmZpY0NvbnRyb2w8L2tleT4KCQkJPGRpY3Q+CgkJCQk8a2V5PkFwcHM8L2tleT4KCQkJCTxhcnJheS8+CgkJCQk8a2V5PkVuYWJsZWQ8L2tleT4KCQkJCTxmYWxzZS8+CgkJCQk8a2V5PkZRRE5zPC9rZXk+CgkJCQk8YXJyYXkvPgoJCQkJPGtleT5Nb2RlPC9rZXk+CgkJCQk8aW50ZWdlcj4yPC9pbnRlZ2VyPgoJCQk8L2RpY3Q+CgkJCTxrZXk+VXNlRXh0ZXJuYWxCcm93c2VyPC9rZXk+CgkJCTxpbnRlZ2VyPjA8L2ludGVnZXI+CgkJCTxrZXk+VXNlcjwva2V5PgoJCQk8c3RyaW5nPjwvc3RyaW5nPgoJCQk8a2V5PlZwblR5cGU8L2tleT4KCQkJPGludGVnZXI+MDwvaW50ZWdlcj4KCQkJPGtleT5XYXJuSW52YWxpZFNlcnZlckNlcnRpZmljYXRlPC9rZXk+CgkJCTxpbnRlZ2VyPjE8L2ludGVnZXI+CgkJPC9kaWN0PgoJPC9kaWN0PgoJPGtleT5TZWN1cmVSZW1vdGVBY2Nlc3M8L2tleT4KCTxpbnRlZ2VyPjA8L2ludGVnZXI+Cgk8a2V5PlNzbFNob3VsZEJsb2NrSXB2Njwva2V5PgoJPGludGVnZXI+MTwvaW50ZWdlcj4KCTxrZXk+U3VwcHJlc3NWcG5Ob3RpZmljYXRpb248L2tleT4KCTxpbnRlZ2VyPjA8L2ludGVnZXI+Cgk8a2V5PlZwbkN1cnJlbnRDb25uZWN0PC9rZXk+Cgk8c3RyaW5nPjwvc3RyaW5nPgoJPGtleT5WcG5DdXJyZW50Q29ubmVjdFR5cGU8L2tleT4KCTxzdHJpbmc+PC9zdHJpbmc+Cgk8a2V5Pldhcm5JbnZhbGlkU2VydmVyQ2VydGlmaWNhdGU8L2tleT4KCTxpbnRlZ2VyPjE8L2ludGVnZXI+CjwvZGljdD4KPC9wbGlzdD4K"
VPN_CONF_PATH="/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

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

# --- 4. Nettoyage préventif des FortiClient.dmg orphelins (>1h) ---
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

while [ -z "$FINAL_DMG_PATH" ]; do
    # Cherche un FortiClient.dmg récent
    CANDIDATE=$(find /var/folders -type f -name "FortiClient.dmg" -path "*/fctupdate/*" -mmin -30 2>/dev/null | head -n 1)

    if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ]; then
        # Mesure 1 de la taille
        SIZE1=$(stat -f%z "$CANDIDATE" 2>/dev/null || echo 0)
        sleep 5
        # Mesure 2 après 5s
        SIZE2=$(stat -f%z "$CANDIDATE" 2>/dev/null || echo 0)

        if [ "$SIZE1" = "$SIZE2" ] && [ "$SIZE1" -ge "$MIN_SIZE" ]; then
            # Taille stable et minimum atteint → on valide l'intégrité du DMG
            SIZE_MB=$((SIZE1 / 1024 / 1024))
            log "  Size stable at ${SIZE_MB} MB — verifying DMG integrity..."

            if hdiutil imageinfo "$CANDIDATE" >/dev/null 2>&1; then
                # DMG complet et structurellement valide
                FINAL_DMG_PATH="$CANDIDATE"
                log "  ✓ DMG integrity OK"
                break
            else
                log "  ⚠ DMG not yet valid (still being written?) — continuing to wait"
            fi
        else
            # Taille encore en évolution → download en cours
            SIZE_MB=$((SIZE2 / 1024 / 1024))
            log "  Download in progress: ${SIZE_MB} MB ($SIZE1 → $SIZE2 bytes)"
        fi
        WAITED=$((WAITED + 5))
    else
        # Pas encore de fichier détecté
        sleep 2
        WAITED=$((WAITED + 2))
        if [ $((WAITED % LOG_INTERVAL)) -eq 0 ]; then
            log "  Still waiting for file to appear... (${WAITED}s elapsed, max ${MAX_WAIT}s)"
        fi
    fi

    # Sécurité : l'installer a-t-il crashé ?
    if ! kill -0 "$INSTALLER_PID" 2>/dev/null; then
        log "[ERROR] FortiClientInstaller a quitté avant d'avoir produit un DMG complet"
        exit 1
    fi

    # Timeout global
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        log "[ERROR] Timeout : FortiClient.dmg pas complet après ${MAX_WAIT}s"
        exit 1
    fi
done

FINAL_SIZE=$(du -h "$FINAL_DMG_PATH" | awk '{print $1}')
log "FortiClient.dmg ready: $FINAL_DMG_PATH ($FINAL_SIZE, ${WAITED}s elapsed)"

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

# --- 13. Injection de la config VPN partagée ---
# Le postinstall Fortinet vient de lancer FortiTray + FortiClientAgent. Il faut
# les arrêter avant d'écrire vpn.plist, sinon ils tiendraient l'ancienne config
# (vide) en mémoire et ne reliraient pas le fichier qu'on pose.
if [ -n "$VPN_PLIST_B64" ]; then
    log "Injecting shared VPN config..."

    # Stoppe les agents userspace + le service root pour libérer toute lecture en cours
    log "  Stopping Fortinet processes to safely write VPN config..."
    pkill -9 -i -f "FortiTray|FortiClientAgent|FctMiscAgent|CredentialStore|FortiClient\.app/Contents/MacOS/FortiClient" 2>/dev/null || true
    sleep 2

    # Crée le dossier de config (devrait déjà exister mais sécurité)
    mkdir -p "$(dirname "$VPN_CONF_PATH")"

    # Décode le base64 et écrit le fichier
    if echo "$VPN_PLIST_B64" | base64 -D > "$VPN_CONF_PATH" 2>/dev/null; then
        chown root:wheel "$VPN_CONF_PATH"
        chmod 0644 "$VPN_CONF_PATH"
        VPN_BYTES=$(stat -f%z "$VPN_CONF_PATH" 2>/dev/null || echo "?")
        log "  ✓ Wrote $VPN_CONF_PATH (${VPN_BYTES} bytes, root:wheel 0644)"

        # Vérifie que c'est un plist valide
        if plutil -lint "$VPN_CONF_PATH" >/dev/null 2>&1; then
            log "  ✓ Plist syntax valid"
        else
            log "  [WARN] Plist syntax check failed — config may not load properly"
        fi
    else
        log "  [ERROR] Failed to decode VPN config from base64"
    fi

    # Redémarre les agents Fortinet pour qu'ils relisent la nouvelle config
    log "  Restarting Fortinet daemons (system domain)..."
    for daemon in /Library/LaunchDaemons/com.fortinet.*.plist; do
        [ -e "$daemon" ] || continue
        launchctl bootout system "$daemon" 2>/dev/null || true
        launchctl bootstrap system "$daemon" 2>/dev/null \
            || launchctl load "$daemon" 2>/dev/null \
            || true
    done

    log "  Restarting Fortinet agents (user GUI session)..."
    VPN_CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
    VPN_CONSOLE_UID=$(id -u "$VPN_CONSOLE_USER" 2>/dev/null || echo "")
    if [ -n "$VPN_CONSOLE_UID" ] && [ "$VPN_CONSOLE_UID" != "0" ]; then
        for agent in /Library/LaunchAgents/com.fortinet.*.plist; do
            [ -e "$agent" ] || continue
            launchctl bootout "gui/$VPN_CONSOLE_UID" "$agent" 2>/dev/null || true
            launchctl bootstrap "gui/$VPN_CONSOLE_UID" "$agent" 2>/dev/null \
                || launchctl asuser "$VPN_CONSOLE_UID" launchctl load "$agent" 2>/dev/null \
                || true
        done
    else
        log "  [WARN] No user logged in GUI — agents will load at next login with the new config"
    fi
else
    log "No shared VPN config to inject (vpn.plist was absent at build time)."
fi

# --- 14. Démonter FortiClient.dmg avant cleanup ---
hdiutil detach "$FC_MOUNT" -force -quiet 2>/dev/null || true
log "FortiClient.dmg unmounted."

# --- 15. Cleanup du FortiClient.dmg téléchargé (~400 Mo) ---
log "Cleaning up downloaded FortiClient.dmg cache..."
if [ -n "$FINAL_DMG_PATH" ] && [ -f "$FINAL_DMG_PATH" ]; then
    rm -f "$FINAL_DMG_PATH" 2>/dev/null || true
    log "  Removed $FINAL_DMG_PATH"
    FCTUPDATE_DIR=$(dirname "$FINAL_DMG_PATH")
    if [ -d "$FCTUPDATE_DIR" ]; then
        if rmdir "$FCTUPDATE_DIR" 2>/dev/null; then
            log "  Removed empty $FCTUPDATE_DIR"
        else
            log "  Kept $FCTUPDATE_DIR (not empty)"
        fi
    fi
fi

# --- 16. Vérification post-install ---
if [ -d "$APP_PATH" ]; then
    NEW_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: FortiClient $NEW_VERSION"
else
    log "[WARN] $APP_PATH not found after install"
fi

log "=== FortiClient install/update successful ==="
exit 0
