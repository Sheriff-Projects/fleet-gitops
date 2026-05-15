#!/bin/bash

# Uninstall script FortiClient VPN
set -o pipefail
LOG="/var/log/forticlient_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== FortiClient uninstall started ==="

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="${SUDO_USER:-${CONSOLE_USER:-${USER:-root}}}"
log "Running as REAL_USER=$REAL_USER (CONSOLE_USER=$CONSOLE_USER)"

ProgramList=("FortiClient" "FortiTray" "FortiClientAgent" "FortiClientNetworkAccessControl" "fctclient" "FortiSSLVPNXdaemon" "FortiClientInstaller")
for p in "${ProgramList[@]}"; do
    PIDS=$(pgrep -f "$p" 2>/dev/null || true)
    for pid in $PIDS; do
        log "  kill $p ($pid)"
        kill -9 "$pid" 2>/dev/null || true
    done
done
sleep 1

for a in /Library/LaunchAgents/com.fortinet.*.plist; do
    [ -e "$a" ] || continue
    log "  unload agent $a"
    if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/$CONSOLE_UID" "$a" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl unload "$a" 2>/dev/null \
            || true
    fi
done

for d in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "$d" ] || continue
    log "  unload daemon $d"
    launchctl bootout system "$d" 2>/dev/null \
        || launchctl unload "$d" 2>/dev/null \
        || true
done
sleep 1

# --- Désactivation des System Extensions Fortinet ---
# Tant que la NetworkExtension VPN est active, macOS refuse de supprimer l'app
# qui la fournit (FortiClient.app). On la désactive avant le rm.
log "Deactivating Fortinet System Extensions..."
SYSEXT_LIST=$(systemextensionsctl list 2>/dev/null | grep -i "fortinet\|forticlient" || true)
if [ -n "$SYSEXT_LIST" ]; then
    log "  Found system extensions to uninstall:"
    echo "$SYSEXT_LIST" | tee -a "$LOG"
    # Le team ID Fortinet est AH4XFXJ7DK pour toutes les extensions
    for ext_id in $(echo "$SYSEXT_LIST" | awk '{for(i=1;i<=NF;i++) if($i ~ /^com\.fortinet/) print $i}' | sort -u); do
        log "  uninstall $ext_id"
        systemextensionsctl uninstall AH4XFXJ7DK "$ext_id" 2>>"$LOG" || true
    done
    sleep 2
else
    log "  No Fortinet system extensions found"
fi

# Helper de suppression robuste — gère les obstacles fréquents qui font échouer rm -rf :
#   - xattr com.apple.macl (protection TCC)
#   - flags système (schg, uchg)
#   - permissions restrictives
#   - ownership non-root (install drag-and-drop)
# Si rm échoue malgré tout, fallback mv→/tmp puis rm.
robust_remove() {
    local target="$1"
    [ -e "$target" ] || [ -L "$target" ] || return 0

    # 1. Effacer toutes les xattrs (notamment com.apple.macl posée par TCC)
    xattr -cr "$target" 2>/dev/null || true
    # 2. Effacer les flags système d'immutabilité (schg, uchg, appnd)
    chflags -R noschg,nouchg,noappnd "$target" 2>/dev/null || true
    # 3. S'assurer que root a les droits d'écriture
    chmod -R u+w "$target" 2>/dev/null || true
    # 4. Reprendre l'ownership si l'app a été installée drag-and-drop
    chown -R root:wheel "$target" 2>/dev/null || true


    # 5. Tentative directe
    if rm -rf "$target" 2>>"$LOG"; then
        log "  ✓ rm $target"
        return 0
    fi

    # 6. Fallback : mv vers /tmp puis rm depuis là (contourne certaines protections
    #    quand le parent dir bloque la suppression directe)
    local trash="/tmp/.forticlient_trash_$$_$(date +%s)"
    if mv "$target" "$trash" 2>>"$LOG"; then
        rm -rf "$trash" 2>/dev/null || true
        log "  ✓ rm (via mv→/tmp) $target"
        return 0
    fi

    log "  ✗ Could not remove $target — kept on disk (Operation not permitted?)"
    return 1
}

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
    robust_remove "$f"
done

log "Sweeping leftover Fortinet files..."
find /Library/LaunchAgents -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/Preferences -maxdepth 1 -iname "com.fortinet.*" -exec rm -rf {} \; 2>/dev/null || true

log "Cleaning up online installer cache (fctupdate)..."
find /var/folders -type d -name "fctupdate" -exec rm -rf {} \; 2>/dev/null || true

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

FortiPkgs=$(pkgutil --pkgs | grep -iE "fortinet|forticlient" || true)
if [ -n "$FortiPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget $pkg"
        pkgutil --forget "$pkg" 2>/dev/null || true
    done <<< "$FortiPkgs"
fi
pkgutil --forget "com.fortinet.FortiClient" 2>/dev/null || true

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
