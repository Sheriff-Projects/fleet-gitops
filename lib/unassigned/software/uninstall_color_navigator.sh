#!/bin/bash
# Uninstall script EIZO ColorNavigator 7
set -o pipefail
LOG="/var/log/color_navigator_uninstall.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
log "=== EIZO ColorNavigator uninstall started ==="

# Détection de l'utilisateur, robuste même quand le script tourne via fleetd
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")
REAL_USER="${SUDO_USER:-${CONSOLE_USER:-${USER:-root}}}"
log "Running as REAL_USER=$REAL_USER (CONSOLE_USER=$CONSOLE_USER)"

# --- 1. Kill running EIZO/ColorNavigator processes ---
ProgramList=("ColorNavigator" "ColorNavigator 7" "ColorNavigatorAgent" "ColorNavigatorNetworkClient" "EIZO")
for p in "${ProgramList[@]}"; do
    PIDS=$(pgrep -f "$p" 2>/dev/null || true)
    for pid in $PIDS; do log "  kill $p ($pid)"; kill -9 "$pid" 2>/dev/null || true; done
done
sleep 1

# --- 2. Unload des LaunchAgents EIZO ---
for a in /Library/LaunchAgents/jp.co.eizo.*.plist; do
    [ -e "$a" ] || continue
    log "  unload agent $a"
    if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
        launchctl bootout "gui/$CONSOLE_UID" "$a" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl unload "$a" 2>/dev/null \
            || true
    fi
done

# --- 3. Unload des LaunchDaemons EIZO ---
for d in /Library/LaunchDaemons/jp.co.eizo.*.plist; do
    [ -e "$d" ] || continue
    log "  unload daemon $d"
    launchctl bootout system "$d" 2>/dev/null \
        || launchctl unload "$d" 2>/dev/null \
        || true
done
sleep 1

# --- 4. Suppression des fichiers ---
FilesToRemove=(
    "/Applications/ColorNavigator 7.app"
    "/Applications/ColorNavigator.app"
    "/Library/Application Support/EIZO"
    "/Library/Application Support/ColorNavigator"
    "/Library/Application Support/ColorNavigator 7"
    "/Library/Preferences/jp.co.eizo.ColorNavigator7.plist"
    "/Library/PrivilegedHelperTools/jp.co.eizo.ColorNavigator7Helper"
)
for f in "${FilesToRemove[@]}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        log "  rm $f"; rm -rf "$f" 2>/dev/null || log "    (échec)"
    fi
done

# Sweep large : tout fichier EIZO restant dans /Library
log "Sweeping leftover EIZO files..."
find /Library/LaunchAgents -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/LaunchDaemons -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \; 2>/dev/null || true
find /Library/PrivilegedHelperTools -maxdepth 1 -iname "jp.co.eizo.*" -exec rm -rf {} \; 2>/dev/null || true

# --- 5. Cleanup ~/Library de tous les utilisateurs ---
for userdir in /Users/*; do
    [ -d "$userdir" ] || continue
    [ "$(basename "$userdir")" = "Shared" ] && continue
    for path in \
        "$userdir/Library/Application Support/EIZO" \
        "$userdir/Library/Application Support/ColorNavigator" \
        "$userdir/Library/Application Support/ColorNavigator 7" \
        "$userdir/Library/Preferences/jp.co.eizo.ColorNavigator7.plist" \
        "$userdir/Library/Preferences/jp.co.eizo.ColorNavigator.plist" \
        "$userdir/Library/Caches/jp.co.eizo.ColorNavigator7" \
        "$userdir/Library/Caches/jp.co.eizo.ColorNavigator"
    do
        if [ -e "$path" ] || [ -L "$path" ]; then
            log "  rm $path"; rm -rf "$path" 2>/dev/null || true
        fi
    done
done

# --- 6. Forget pkg receipts ---
EizoPkgs=$(pkgutil --pkgs | grep -iE "eizo|colornavigator" || true)
if [ -n "$EizoPkgs" ]; then
    while IFS= read -r pkg; do
        log "  pkgutil --forget $pkg"
        pkgutil --forget "$pkg" 2>/dev/null || true
    done <<< "$EizoPkgs"
fi
pkgutil --forget "com.eizo.ColorNavigator7" 2>/dev/null || true

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

log "  Cache cleared"

log "=== EIZO ColorNavigator uninstall finished ==="
exit 0
