#!/bin/bash
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

rm -Rfv "/Applications/FortiClient.app"
rm -Rfv "/Applications/FortiClientUninstaller.app"

FilesToRemove=(
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
