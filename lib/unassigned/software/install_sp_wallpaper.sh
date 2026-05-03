#!/bin/bash
# Fleet passes the PKG path via $INSTALLER_PATH
# This just runs the PKG, which contains the real install logic as postinstall script
installer -pkg "$INSTALLER_PATH" -target /

username=$(stat -f%Su /dev/console)

# Ajouter des fonds d'écran aux Préférences Système
sudo rm /Users/$username/Library/Preferences/com.apple.systempreferences.plist
sudo killall -HUP cfprefsd

# Ajouter le chemin des fonds d'écran aux Préférences Système
sudo defaults write /Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/Wallpapers_SP</string></array></dict>'
defaults write /Users/$username/Library/Preferences/com.apple.systempreferences DSKDesktopPrefPane '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/Wallpapers_SP</string></array></dict>'

sudo killall -HUP cfprefsd
killall "System Settings"