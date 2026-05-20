#!/bin/bash
# Uninstall script Wacom Tablet
set -o pipefail
LOG="/var/log/wacom_tablet_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== Wacom Tablet uninstall started ==="

# Détection de l'utilisateur, robuste même quand le script tourne via fleetd
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="${SUDO_USER:-${CONSOLE_USER:-${USER:-root}}}"
log "Running as REAL_USER=$REAL_USER (CONSOLE_USER=$CONSOLE_USER)"

ProgramList=("WacomTabletDriver" "WacomTouchDriver" "TabletDriver" "Wacom Tablet Utility" "Wacom Desktop Center" "Wacom Center" "Wacom Experience Program" "UpgradeHelper" "Wacom_IOManager" "com.wacom.UpdateHelper" "com.wacom.DataStoreMgr")
for p in "${ProgramList[@]}"; do
    PIDS=$(pgrep -f "$p" 2>/dev/null || true)
    for pid in $PIDS; do log "  kill $p ($pid)"; kill -9 "$pid" 2>/dev/null || true; done
done
sleep 1

# Unload des LaunchAgents — préférer bootout dans le domaine GUI de l'utilisateur
for a in /Library/LaunchAgents/com.wacom.DataStoreMgr.plist /Library/LaunchAgents/com.wacom.wacomtablet.plist /Library/LaunchAgents/com.wacom.DisplayMgr.plist /Library/LaunchAgents/com.wacom.IOManager.plist; do
    [ -e "$a" ] || continue
    log "  unload agent $a"
    if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/$CONSOLE_UID" "$a" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl unload "$a" 2>/dev/null \
            || true
    fi
done

# Unload des LaunchDaemons
for d in /Library/LaunchDaemons/com.wacom.DisplayHelper.plist /Library/LaunchDaemons/com.wacom.displayhelper.plist /Library/LaunchDaemons/com.wacom.UpdateHelper.plist /Library/LaunchDaemons/com.wacom.TabletHelper.plist; do
    [ -e "$d" ] || continue
    log "  unload daemon $d"
    launchctl bootout system "$d" 2>/dev/null \
        || launchctl unload "$d" 2>/dev/null \
        || true
done
sleep 1

for k in com.Wacom.iokit.TabletDriver com.wacom.kext.wacomtablet com.wacom.kext.ftdi com.wacom.WacomTabletHIDDevice; do
    /sbin/kextunload -m "$k" 2>/dev/null || true
done

FilesToRemove=(
    /Library/LaunchAgents/com.wacom.DataStoreMgr.plist
    /Library/LaunchAgents/com.wacom.wacomtablet.plist
    /Library/LaunchAgents/com.wacom.DisplayMgr.plist
    /Library/LaunchAgents/com.wacom.IOManager.plist
    /Library/LaunchDaemons/com.wacom.DisplayHelper.plist
    /Library/LaunchDaemons/com.wacom.displayhelper.plist
    /Library/LaunchDaemons/com.wacom.UpdateHelper.plist
    /Library/LaunchDaemons/com.wacom.TabletHelper.plist
    "/Applications/Wacom Tablet.localized"
    /Applications/WacomTablet
    /Applications/Tablet.localized
    "/Library/Application Support/Tablet"
    /Library/PreferencePanes/WacomTablet.prefPane
    "/Library/PreferencePanes/Wacom Tablet.prefPane"
    "/Library/PreferencePanes/Pen Tablet.prefPane"
    /Library/PreferencePanes/Tablet.prefPane
    /Library/PrivilegedHelperTools/com.wacom.TabletHelper.app
    /Library/PrivilegedHelperTools/com.wacom.IOmanager.app
    /Library/PrivilegedHelperTools/com.wacom.UpdateHelper.app
    /Library/PrivilegedHelperTools/com.wacom.DataStoreMgr.app
    /Library/PrivilegedHelperTools/Wacom_IOManager.app
    /Library/Extensions/TabletDriver.kext
    /Library/Extensions/WacomTablet.kext
    "/Library/Internet Plug-Ins/WacomTabletPlugin.plugin"
    "/Library/Internet Plug-Ins/WacomSafari.plugin"
    /Library/Preferences/Tablet
)
for f in "${FilesToRemove[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        log "  rm $f"; rm -rf "$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout prefPane qui matche wacom/tablet
log "Sweeping leftover Wacom prefPanes..."
find /Library/PreferencePanes -maxdepth 1 -iname "*wacom*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/PreferencePanes -maxdepth 1 -iname "*tablet*" -exec rm -rf {} \; 2>/dev/null || true

for userdir in /Users/*; do
    [ -d "$userdir" ] || continue
    [ "$(basename "$userdir")" = "Shared" ] && continue
    for path in \
        "$userdir/Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver" \
        "$userdir/Library/Group Containers/group.EG27766DY7.com.wacom.WacomTabletDriver" \
        "$userdir/Library/Group Containers/group.com.wacom.TabletDriver" \
        "$userdir/Library/Containers/com.wacom.wacomtablet" \
        "$userdir/Library/Application Support/Wacom" \
        "$userdir/Library/Preferences/com.wacom.Wacom-Desktop-Center.plist"
    do
        if [ -e "$path" ] || [ -L "$path" ]; then
            log "  rm $path"; rm -rf "$path" 2>/dev/null || true
        fi
    done
done

WacomPkgs=$(pkgutil --pkgs | grep -i wacom || true)
if [ -n "$WacomPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget $pkg"
        pkgutil --forget "$pkg" 2>/dev/null || true
    done <<< "$WacomPkgs"
fi
pkgutil --forget "com.wacom.WacomCenter" 2>/dev/null || true

# --- Vider le cache de Réglages Système (icône fantôme) ---
log "Clearing System Settings cache..."
killall "System Preferences" 2>/dev/null || true
killall "System Settings" 2>/dev/null || true

# Le cache de l'utilisateur connecté (CONSOLE_USER déjà détecté en haut)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_HOME=$(eval echo ~"$CONSOLE_USER")
    rm -rf "$CONSOLE_HOME/Library/Caches/com.apple.preferencepanes.usercache" 2>/dev/null || true
    rm -rf "$CONSOLE_HOME/Library/Caches/com.apple.systempreferences" 2>/dev/null || true
    sudo -u "$CONSOLE_USER" killall cfprefsd 2>/dev/null || true
fi

# Aussi pour root au cas où
rm -rf /var/root/Library/Caches/com.apple.preferencepanes.usercache 2>/dev/null || true
rm -rf /var/root/Library/Caches/com.apple.systempreferences 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

log "  Cache cleared"

log "=== Wacom Tablet uninstall finished ==="
exit 0
