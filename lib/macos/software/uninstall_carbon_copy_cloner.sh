#!/bin/bash

set -uo pipefail

LOG="/var/log/carbon_copy_cloner_uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Carbon Copy Cloner uninstall started ==="

# --- 1. Quitter CCC s'il tourne ---
if pgrep -x "Carbon Copy Cloner" > /dev/null; then
    log "Quitting Carbon Copy Cloner..."
    osascript -e 'tell application "Carbon Copy Cloner" to quit' 2>/dev/null || true
    sleep 3
    pkill -9 -x "Carbon Copy Cloner" 2>/dev/null || true
fi

# --- 2. Désactiver et supprimer le privileged helper ---
# CCC installe un LaunchDaemon en root pour ses opérations système.
# Le nom exact peut varier selon la version, on couvre les cas connus.
HELPER_PLISTS=(
    "/Library/LaunchDaemons/com.bombich.ccchelper.plist"
    "/Library/LaunchDaemons/com.bombich.ccc.privilegedhelper.plist"
)

for plist in "${HELPER_PLISTS[@]}"; do
    if [ -f "$plist" ]; then
        log "Unloading helper: $plist"
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    fi
done

# Le binaire du helper
HELPER_BINARIES=(
    "/Library/PrivilegedHelperTools/com.bombich.ccchelper"
    "/Library/PrivilegedHelperTools/com.bombich.ccc.privilegedhelper"
)

for binary in "${HELPER_BINARIES[@]}"; do
    if [ -f "$binary" ]; then
        log "Removing helper binary: $binary"
        rm -f "$binary"
    fi
done

# --- 3. Supprimer l'app ---
APP_PATH="/Applications/Carbon Copy Cloner.app"
if [ -d "$APP_PATH" ]; then
    log "Removing $APP_PATH"
    rm -rf "$APP_PATH"
fi

# --- 4. Supprimer les preferences système ---
log "Removing system preferences..."
rm -f /Library/Preferences/com.bombich.ccc.plist
rm -f /Library/Preferences/com.bombich.ccchelper.plist

# --- 5. Supprimer les fichiers de support système ---
log "Removing system support files..."
rm -rf "/Library/Application Support/com.bombich.ccc"
rm -rf "/Library/Logs/CCC"

# --- 6. Supprimer les fichiers de support et prefs de chaque utilisateur ---
# CCC stocke des données dans le profil de chaque utilisateur du Mac
log "Removing per-user data..."
for user_home in /Users/*/; do
    user=$(basename "$user_home")
    
    # Skip les comptes système et invités
    case "$user" in
        Shared|Guest|.localized) continue ;;
    esac
    
    if [ ! -d "$user_home" ]; then
        continue
    fi
    
    log "  Cleaning user: $user"
    rm -rf "$user_home/Library/Application Support/com.bombich.ccc" 2>/dev/null || true
    rm -rf "$user_home/Library/Application Support/Carbon Copy Cloner" 2>/dev/null || true
    rm -rf "$user_home/Library/Caches/com.bombich.ccc" 2>/dev/null || true
    rm -f "$user_home/Library/Preferences/com.bombich.ccc.plist" 2>/dev/null || true
    rm -rf "$user_home/Library/Logs/CCC" 2>/dev/null || true
done

# --- 7. Forget les receipts pkg ---
# Pour que pkgutil --pkgs ne liste plus CCC
log "Forgetting pkg receipts..."
pkgutil --forget com.bombich.ccc.pkg 2>/dev/null || true
pkgutil --forget com.bombich.ccc 2>/dev/null || true

log "=== Uninstall complete ==="
exit 0



