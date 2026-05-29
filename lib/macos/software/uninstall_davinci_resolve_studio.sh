#!/bin/bash
# Uninstall script DaVinci Resolve Studio
#
# Adapté du script officiel d'uninstall embarqué dans le PKG Blackmagic.
# Préserve les préférences et données utilisateur (projets, etc.) au cas où
# l'utilisateur souhaite réinstaller plus tard. Si tu veux un wipe total,
# décommente les lignes en bas du script.

set -uo pipefail

LOG="/var/log/davinci_resolve_uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== DaVinci Resolve Studio uninstall started ==="

# -------------------------------------------------------------------------
# 1. Quitter DaVinci Resolve s'il tourne
# -------------------------------------------------------------------------
if pgrep -x "DaVinci Resolve" > /dev/null; then
    log "DaVinci Resolve est ouvert, on lui demande de quitter..."
    osascript -e 'tell application "DaVinci Resolve" to quit' 2>/dev/null || true

    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x "DaVinci Resolve" > /dev/null; then
            log "DaVinci Resolve quitté après $((i*3))s"
            break
        fi
        sleep 3
    done

    if pgrep -x "DaVinci Resolve" > /dev/null; then
        log "[WARN] DaVinci Resolve n'a pas quitté, force kill"
        pkill -9 -x "DaVinci Resolve" 2>/dev/null || true
        sleep 2
    fi
fi

# -------------------------------------------------------------------------
# 2. Unconfigure panel + display port
#    (à faire AVANT de supprimer l'app, sinon ces scripts n'existent plus)
# -------------------------------------------------------------------------
CONFIGURE_PANEL="/Library/Application Support/Blackmagic Design/DaVinci Resolve/configure-panel.sh"
CONFIGURE_DP="/Library/Application Support/Blackmagic Design/DaVinci Resolve/configure-dp.sh"

if [ -x "$CONFIGURE_PANEL" ]; then
    log "Unconfigure panel..."
    "$CONFIGURE_PANEL" none 2>>"$LOG" || true
fi

if [ -x "$CONFIGURE_DP" ]; then
    log "Unconfigure display port..."
    "$CONFIGURE_DP" off 2>>"$LOG" || true
fi

# -------------------------------------------------------------------------
# 3. Proxy Generator (Studio = full, sinon Lite)
# -------------------------------------------------------------------------
if [ -e "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/Blackmagic Proxy Generator" ]; then
    log "Suppression de Blackmagic Proxy Generator (version Studio)..."
    /bin/rm -rf "/Applications/Blackmagic Proxy Generator.app"
elif [ -e "/Applications/Blackmagic Proxy Generator Lite.app/Contents/Info.plist" ]; then
    # Vérifie que le bundle Lite n'est PAS un standalone (sinon on ne touche pas)
    if grep -q ">com.blackmagic-design.BlackmagicProxyGeneratorLite<" \
        "/Applications/Blackmagic Proxy Generator Lite.app/Contents/Info.plist" 2>/dev/null; then
        log "Suppression de Blackmagic Proxy Generator Lite..."
        /bin/rm -rf "/Applications/Blackmagic Proxy Generator Lite.app"
    fi
fi

# -------------------------------------------------------------------------
# 4. Application principale
# -------------------------------------------------------------------------
if [ -d "/Applications/DaVinci Resolve" ]; then
    log "Suppression de /Applications/DaVinci Resolve/"
    /bin/rm -rf "/Applications/DaVinci Resolve/"
fi

# -------------------------------------------------------------------------
# 5. Panels
# -------------------------------------------------------------------------
log "Suppression des frameworks et supports panneaux..."
/bin/rm -rf "/Library/Frameworks/DaVinciPanelAPI.framework"
/bin/rm -rf "/Library/Application Support/Blackmagic Design/DaVinci Resolve Panels/AdminUtility"
/bin/rmdir "/Library/Application Support/Blackmagic Design/DaVinci Resolve Panels" 2>/dev/null || true

# -------------------------------------------------------------------------
# 6. Fairlight Panels
# -------------------------------------------------------------------------
/bin/rm -rf "/Library/Frameworks/FairlightPanelAPI.framework"

# -------------------------------------------------------------------------
# 7. Resolve Plugin OFX
# -------------------------------------------------------------------------
/bin/rm -rf "/Library/OFX/Plugins/DaVinci Resolve Renderer.ofx.bundle"

# -------------------------------------------------------------------------
# 8. Receipts pkgutil (oublier les .pkg installés)
# -------------------------------------------------------------------------
log "Nettoyage des receipts pkgutil..."
pkgutil --pkgs 2>/dev/null | grep -iE 'blackmagic|davinci|resolve' | while read -r pkg_id; do
    log "  pkgutil --forget $pkg_id"
    pkgutil --forget "$pkg_id" 2>>"$LOG" || true
done

# -------------------------------------------------------------------------
# 9. (OPTIONNEL) Wipe total des préférences et données utilisateur
#    Décommente si tu veux un uninstall complet sans préserver les projets.
# -------------------------------------------------------------------------
# log "Suppression Application Support et Preferences..."
# /bin/rm -rf "/Library/Application Support/Blackmagic Design/DaVinci Resolve/"
# /bin/rm -rf "/Library/Preferences/Blackmagic Design/DaVinci Resolve/"

log "=== DaVinci Resolve Studio uninstall successful ==="
exit 0