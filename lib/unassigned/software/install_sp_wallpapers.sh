#!/bin/bash
# Fleet passes the PKG path via $INSTALLER_PATH
# This just runs the PKG, which contains the real install logic as postinstall script
set -uo pipefail

LOG="/var/log/sp_wallpapers_install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== S•P Wallpapers install started ==="

installer -pkg "$INSTALLER_PATH" -target /
log "  Cleaning user: 1"
username=$(stat -f%Su /dev/console)
log "  Cleaning user: 2"

# Ajouter des fonds d'écran aux Préférences Système
rm /Users/$username/Library/Preferences/com.apple.systempreferences.plist
log "  Cleaning user: 3"
killall -HUP cfprefsd
log "  Cleaning user: 4"
# Ajouter le chemin des fonds d'écran aux Préférences Système

defaults write /Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>'

log "  Cleaning user: 5"
defaults write /Users/$username/Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>'
log "  Cleaning user: 6"

killall -HUP cfprefsd

log "  Cleaning user: 7"
killall "System Settings"