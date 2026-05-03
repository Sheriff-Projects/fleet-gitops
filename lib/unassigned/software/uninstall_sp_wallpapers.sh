#!/bin/bash
# Désinstallation de S•P Wallpapers

set -uo pipefail

LOG="/var/log/sp_wallpapers_uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== S•P Wallpapers uninstall started ==="

exit 0
