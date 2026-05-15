#!/bin/bash
# Uninstall script FortiClient VPN config
# Supprime le vpn.plist partagé et redémarre les agents (qui repartent sans config).

set -o pipefail

LOG="/var/log/forticlient_vpn_config_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== FortiClient VPN config uninstall started ==="

VPN_CONF_PATH="/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

# Stoppe les agents (ils tiennent la config en mémoire)
log "Stopping Fortinet agents..."
pkill -9 -i -f "FortiTray|FortiClientAgent|FctMiscAgent|CredentialStore|FortiClient\.app/Contents/MacOS/FortiClient" 2>/dev/null || true
sleep 2

# Supprime le fichier de config
if [ -f "$VPN_CONF_PATH" ]; then
    log "Removing $VPN_CONF_PATH"
    rm -f "$VPN_CONF_PATH" 2>/dev/null || log "  [WARN] removal failed"
else
    log "vpn.plist already absent"
fi

# Forget le receipt du PKG
pkgutil --forget "com.sheriffprojects.forticlient.vpnconfig" 2>/dev/null || true
log "Forgot pkg receipt: com.sheriffprojects.forticlient.vpnconfig"

# Redémarrer les agents (ils repartent avec une config vide)
log "Restarting Fortinet daemons + agents..."
for daemon in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "$daemon" ] || continue
    launchctl bootout system "$daemon" 2>/dev/null || true
    launchctl bootstrap system "$daemon" 2>/dev/null || true
done

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")
if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    for agent in /Library/LaunchAgents/com.fortinet.*.plist; do
        [ -e "$agent" ] || continue
        launchctl bootout "gui/$CONSOLE_UID" "$agent" 2>/dev/null || true
        launchctl bootstrap "gui/$CONSOLE_UID" "$agent" 2>/dev/null || true
    done
fi

log "=== FortiClient VPN config uninstall finished ==="
exit 0
