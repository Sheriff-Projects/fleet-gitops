#!/bin/bash
# Install script EIZO ColorNavigator 7 — appelé par Fleet.
# Télécharge le PKG officiel EIZO et l'installe directement.

set -uo pipefail

TARGET_VERSION="7.2.7"
DOWNLOAD_URL="https://www.eizoglobal.com/support/db/files/software/software/graphics/colornavigator7/ColorNavigator727.pkg"
APP_PATH="/Applications/ColorNavigator 7.app"
TEMP_DIR=$(mktemp -d)
PKG_PATH="$TEMP_DIR/ColorNavigator.pkg"
LOG="/var/log/color_navigator_install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

log "=== EIZO ColorNavigator install/update started (Fleet script) ==="
log "Target version: $TARGET_VERSION"

# --- Check version installée ---
if [ -d "$APP_PATH" ]; then
    INSTALLED_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
    log "Installed version: $INSTALLED_VERSION"
    if [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
        log "Already up to date. Exiting."
        exit 0
    fi
    log "Upgrading from $INSTALLED_VERSION to $TARGET_VERSION..."
else
    log "ColorNavigator not installed, performing fresh install..."
fi

# --- Téléchargement du PKG ---
log "Downloading from $DOWNLOAD_URL..."
if ! curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$PKG_PATH"; then
    log "[ERROR] Download failed"; exit 1
fi

# --- Vérification basique du fichier ---
if [ ! -s "$PKG_PATH" ]; then
    log "[ERROR] PKG téléchargé vide ou invalide"
    exit 1
fi
PKG_DL_SIZE=$(du -h "$PKG_PATH" | awk '{print $1}')
log "Downloaded PKG: $PKG_DL_SIZE"

# --- Installation ---
log "Running installer -pkg ..."
if ! installer -pkg "$PKG_PATH" -target / >> "$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

# --- Chargement des LaunchDaemons EIZO (root) ---
log "Loading EIZO LaunchDaemons (if any)..."
for daemon in /Library/LaunchDaemons/jp.co.eizo.*.plist; do
    [ -e "$daemon" ] || continue
    log "  bootstrap $daemon"
    launchctl bootstrap system "$daemon" 2>/dev/null \
        || launchctl load "$daemon" 2>/dev/null \
        || true
done

# --- Chargement des LaunchAgents EIZO dans la session GUI ---
log "Loading EIZO LaunchAgents in user GUI session..."
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")

if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    log "  Target user: $CONSOLE_USER (uid=$CONSOLE_UID)"
    for agent in /Library/LaunchAgents/jp.co.eizo.*.plist; do
        [ -e "$agent" ] || continue
        log "  bootstrap $agent"
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
    log "Installation verified: ColorNavigator $NEW_VERSION"
else
    log "[WARN] $APP_PATH not found after install"
fi

log "=== EIZO ColorNavigator install/update successful ==="
exit 0
