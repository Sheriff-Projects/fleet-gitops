#!/bin/bash
# Désinstallation de Dark Mode.

set -uo pipefail

LOG="/var/log/dark_mode_uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Dark Mode uninstall started ==="

