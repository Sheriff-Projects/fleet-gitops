#!/bin/bash
# Fleet passes the PKG path via $INSTALLER_PATH
# This just runs the PKG, which contains the real install logic as postinstall script
set -uo pipefail

LOG="/var/log/sp_wallpapers_install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== S•P Wallpapers install started ==="

# Définir l'utilisateur actuel
username=$(stat -f%Su /dev/console)

# Ajouter des fonds d'écran aux Préférences Système
sudo rm /Users/$username/Library/Preferences/com.apple.systempreferences.plist
sudo killall -HUP cfprefsd

# Ajouter le chemin des fonds d'écran aux Préférences Système
sudo defaults write /Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>'
defaults write /Users/$username/Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>'

sudo killall -HUP cfprefsd
killall "System Settings"