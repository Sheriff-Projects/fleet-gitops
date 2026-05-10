#!/bin/bash
# Install script Wacom Tablet — appelé par Fleet (PAS imbriqué dans un autre installer).
# Télécharge le DMG officiel Wacom, l'installe, puis charge les LaunchAgents
# dans la session GUI de l'utilisateur connecté (pour éviter un redémarrage).

set -uo pipefail

TARGET_VERSION="6.4.13-4"
DOWNLOAD_URL="https://cdn.wacom.com/u/productsupport/drivers/mac/professional/WacomTablet_6.4.13-4.dmg"
APP_PATH="/Applications/Wacom Tablet.localized/Wacom Center.app"
TEMP_DIR=$(mktemp -d)
DMG_PATH="$TEMP_DIR/WacomTablet.dmg"
MOUNT_POINT="$TEMP_DIR/WacomTabletMount"
LOG="/var/log/wacom_tablet_install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
cleanup() {
    hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log "=== Wacom Tablet install/update started (Fleet script) ==="
log "Target version: $TARGET_VERSION"

if [ -d "$APP_PATH" ]; then
    INSTALLED_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: $INSTALLED_VERSION"
    if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from $INSTALLED_VERSION to $TARGET_VERSION..."
else
    log "Wacom Center not installed, performing fresh install..."
fi

log "Downloading from $DOWNLOAD_URL..."
if ! curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH"; then
    log "[ERROR] Download failed"; exit 1
fi

log "Mounting DMG..."
mkdir -p "$MOUNT_POINT"
if ! hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet; then
    log "[ERROR] Failed to mount DMG"; exit 1
fi

SOURCE_PKG=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -type f 2>/dev/null | head -n 1)
if [ -z "$SOURCE_PKG" ] || [ ! -f "$SOURCE_PKG" ]; then
    log "[ERROR] Aucun .pkg trouvé dans le DMG"
    ls -la "$MOUNT_POINT" | tee -a "$LOG"
    exit 1
fi
log "Embedded PKG: $SOURCE_PKG"

log "Running installer -pkg ..."
if ! installer -pkg "$SOURCE_PKG" -target / >> "$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- Chargement des LaunchDaemons (root, pas de session requise) ---
log "Loading Wacom LaunchDaemons..."
for daemon in /Library/LaunchDaemons/com.wacom.*.plist; do
    [ -e "$daemon" ] || continue
    log "  bootstrap $daemon"
    launchctl bootstrap system "$daemon" 2>/dev/null \
        || launchctl load "$daemon" 2>/dev/null \
        || true
done

# --- Chargement des LaunchAgents dans la session GUI de l'utilisateur connecté ---
# C'est cette étape qui évite le redémarrage : sans elle, les agents (dont l'icône
# de la barre de menu) ne se chargeraient qu'au prochain login.
log "Loading Wacom LaunchAgents in user GUI session..."
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")

if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    log "  Target user: $CONSOLE_USER (uid=$CONSOLE_UID)"
    for agent in /Library/LaunchAgents/com.wacom.*.plist; do
        [ -e "$agent" ] || continue
        log "  bootstrap $agent"
        # bootstrap = la méthode moderne (Big Sur+)
        # fallback sur asuser+load pour les vieilles versions
        launchctl bootstrap "gui/$CONSOLE_UID" "$agent" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl load "$agent" 2>/dev/null \
            || true
    done
else
    log "  [WARN] Aucun utilisateur connecté en GUI — agents chargés au prochain login"
fi

# --- Vérification post-install ---
if [ -d "$APP_PATH" ]; then
    NEW_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installation verified: Wacom Center $NEW_VERSION"
else
    log "[WARN] $APP_PATH not found after install"
fi

log "=== Wacom Tablet install/update successful ==="
exit 0
