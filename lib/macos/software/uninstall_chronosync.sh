#!/bin/bash
# Script de désinstallation Fleet — ChronoSync  (type : generic_app)
# Exécuté en root par Fleet.
set -euo pipefail
LOG="/var/log/chronosync_uninstall.log"
APP_PATH="/Applications/ChronoSync.app"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== Uninstall ChronoSync ==="


pkill -f "ChronoSync" 2>/dev/null || true

pkill -f "ChronoSync Scheduler" 2>/dev/null || true


osascript -e 'quit app "ChronoSync"' 2>/dev/null || true


CUID=$(stat -f%u /dev/console)




# Supprime l'application
[ -d "$APP_PATH" ] && rm -rf "$APP_PATH" && log "Supprimé : $APP_PATH"

rm -rf "/Applications/ChronoSync.app" 2>/dev/null && log "Supprimé : /Applications/ChronoSync.app" || true

rm -rf "~/Library/Logs/ChronoSync" 2>/dev/null && log "Supprimé : ~/Library/Logs/ChronoSync" || true

rm -rf "~/Library/Preferences/com.econtechnologies.backgrounder.chronosync.plist" 2>/dev/null && log "Supprimé : ~/Library/Preferences/com.econtechnologies.backgrounder.chronosync.plist" || true

rm -rf "~/Library/Preferences/com.econtechnologies.chronosync.plist" 2>/dev/null && log "Supprimé : ~/Library/Preferences/com.econtechnologies.chronosync.plist" || true

rm -rf "~/Library/Saved Application State/com.econtechnologies.chronosync.savedState" 2>/dev/null && log "Supprimé : ~/Library/Saved Application State/com.econtechnologies.chronosync.savedState" || true


pkgutil --forget "com.econtechnologies.pkg.ChronoSyncApplication" 2>/dev/null || true


log "=== Uninstall terminée ==="
exit 0
