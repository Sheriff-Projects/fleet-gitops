#!/bin/bash
set -uo pipefail
LOG="/var/log/desktoppr_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== Uninstall desktoppr ==="
# Binaire CLI : on supprime l'exécutable + on oublie le receipt pkg.
rm -f /usr/local/bin/desktoppr
pkgutil --forget com.scriptingosx.desktoppr 2>/dev/null || true
log "=== Uninstall terminée ==="
exit 0



