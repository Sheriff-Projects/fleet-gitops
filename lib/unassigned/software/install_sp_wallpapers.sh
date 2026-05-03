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

username=$(stat -f%Su /dev/console)

# Ajouter des fonds d'écran aux Préférences Système
rm /Users/$username/Library/Preferences/com.apple.systempreferences.plist
killall -HUP cfprefsd

# Ajouter le chemin des fonds d'écran aux Préférences Système
defaults write /Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/Wallpapers_SP</string></array></dict>'
defaults write /Users/$username/Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/Wallpapers_SP</string></array></dict>'

killall -HUP cfprefsd
killall "System Settings"