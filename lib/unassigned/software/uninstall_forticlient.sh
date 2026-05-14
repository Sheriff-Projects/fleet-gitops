#!/bin/bash
# Uninstall script FortiClient VPN
# Suppression complète de tous les composants Fortinet macOS.
set -o pipefail
LOG="/var/log/forticlient_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== FortiClient uninstall started ==="

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="${SUDO_USER:-${CONSOLE_USER:-${USER:-root}}}"
log "Running as REAL_USER=$REAL_USER (CONSOLE_USER=$CONSOLE_USER)"

# --- 1. Quit / kill des processus FortiClient ---
ProgramList=("FortiClient" "FortiTray" "FortiClientAgent" "FortiClientNetworkAccessControl" "fctclient" "FortiSSLVPNXdaemon" "FortiClientInstaller")
for p in "${ProgramList[@]}"; do
    PIDS=$(pgrep -f "$p" 2>/dev/null || true)
    for pid in $PIDS; do
        log "  kill $p ($pid)"
        kill -9 "$pid" 2>/dev/null || true
    done
done
sleep 1

# --- 2. Unload des LaunchAgents Fortinet ---
for a in /Library/LaunchAgents/com.fortinet.*.plist; do
    [ -e "$a" ] || continue
    log "  unload agent $a"
    if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/$CONSOLE_UID" "$a" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl unload "$a" 2>/dev/null \
            || true
    fi
done

# --- 3. Unload des LaunchDaemons Fortinet ---
for d in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "$d" ] || continue
    log "  unload daemon $d"
    launchctl bootout system "$d" 2>/dev/null \
        || launchctl unload "$d" 2>/dev/null \
        || true
done
sleep 1

# --- 4. Suppression des fichiers système ---
FilesToRemove=(
    /Applications/FortiClient.app
    /Applications/FortiClientUninstaller.app
    /Applications/FortiClientUpdate.app
    "/Library/Application Support/Fortinet"
    "/Library/Application Support/FortiClient"
    /Library/Frameworks/FortiVPN.framework
    /Library/Frameworks/FortiSSLVPNX.framework
    /Library/Frameworks/FortiSSLVPNXLib.framework
    /Library/PrivilegedHelperTools/com.fortinet.forticlient.fctclient
    /Library/PrivilegedHelperTools/com.fortinet.forticlient.uninstall_helper
    /Library/Preferences/com.fortinet.forticlient.plist
    /Library/Preferences/com.fortinet.forticlient.fortishield.plist
)
for f in "${FilesToRemove[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        log "  rm $f"
        rm -rf "$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout fichier Fortinet restant
log "Sweeping leftover Fortinet files..."
find /Library/LaunchAgents -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/Preferences -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true

# Cleanup des artefacts laissés par l'online installer dans /var/folders
log "Cleaning up online installer cache..."
find /var/folders -type d -name "fctupdate" -exec rm -rf {} \; 2>/dev/null || true

# --- 5. Cleanup ~/Library de tous les utilisateurs ---
for userdir in /Users/*; do
    [ -d "$userdir" ] || continue
    [ "$(basename "$userdir")" = "Shared" ] && continue
    find "$userdir/Library/Preferences" -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
    find "$userdir/Library/Caches" -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
    for path in \
        "$userdir/Library/Application Support/Fortinet" \
        "$userdir/Library/Application Support/FortiClient" \
        "$userdir/Library/Logs/FortiClient"
    do
        if [ -e "$path" ] || [ -L "$path" ]; then
            log "  rm $path"
            rm -rf "$path" 2>/dev/null || true
        fi
    done
done

# --- 6. Forget pkg receipts ---
FortiPkgs=$(pkgutil --pkgs | grep -iE "fortinet|forticlient" || true)
if [ -n "$FortiPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget $pkg"
        pkgutil --forget "$pkg" 2>/dev/null || true
    done <<< "$FortiPkgs"
fi
pkgutil --forget "com.fortinet.FortiClient" 2>/dev/null || true

# --- 7. Vider le cache de Réglages Système ---
log "Clearing System Settings cache..."
killall "System Preferences" 2>/dev/null || true
killall "System Settings" 2>/dev/null || true

if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_HOME=$(eval echo ~"$CONSOLE_USER")
    rm -rf "$CONSOLE_HOME/Library/Caches/com.apple.preferencepanes.usercache" 2>/dev/null || true
    rm -rf "$CONSOLE_HOME/Library/Caches/com.apple.systempreferences" 2>/dev/null || true
    sudo -u "$CONSOLE_USER" killall cfprefsd 2>/dev/null || true
fi

rm -rf /var/root/Library/Caches/com.apple.preferencepanes.usercache 2>/dev/null || true
rm -rf /var/root/Library/Caches/com.apple.systempreferences 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

log "=== FortiClient uninstall finished ==="
exit 0
