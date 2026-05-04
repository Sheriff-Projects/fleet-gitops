#!/bin/bash
# Fleet passes the PKG path via $INSTALLER_PATH
# This just runs the PKG, which contains the real install logic as postinstall script
set -uo pipefail

LOG="/var/log/sp_wallpapers_install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

/usr/local/bin/desktoppr /Users/Shared/sp_wallpapers/default.heic
