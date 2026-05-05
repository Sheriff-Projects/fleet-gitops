#!/bin/sh
#
# Fleet install script — DesktopprManage
# Tourne en root via Fleet. $INSTALLER_PATH = chemin du .pkg fourni par Fleet.
#

set -u

LOG="/var/log/desktoppr_manage_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== DesktopprManage install démarré ==="

# ---------------------------------------------------------------------------
# 1. Installation du pkg
# ---------------------------------------------------------------------------
if [ -z "${INSTALLER_PATH:-}" ] || [ ! -f "${INSTALLER_PATH}" ]; then
    log "ERREUR : INSTALLER_PATH non défini ou fichier introuvable"
    exit 1
fi

log "Installation du pkg : ${INSTALLER_PATH}"
if /usr/sbin/installer -pkg "${INSTALLER_PATH}" -target / >>"$LOG" 2>&1; then
    log "Pkg installé"
else
    log "ERREUR : échec de l'installation du pkg"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Charger le LaunchAgent pour l'utilisateur connecté (si présent)
# ---------------------------------------------------------------------------
# Le LaunchAgent se charge automatiquement au prochain login.
# Si un user est déjà connecté au moment de l'install, on le bootstrappe
# pour appliquer le wallpaper immédiatement.

LAUNCH_AGENT="/Library/LaunchAgents/com.scriptingosx.desktopprmanage.plist"

if [ ! -f "${LAUNCH_AGENT}" ]; then
    log "ATTENTION : LaunchAgent ${LAUNCH_AGENT} introuvable après install"
    exit 0
fi

loggedInUser=$(echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil \
    | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')

if [ -n "${loggedInUser}" ]; then
    uid=$(/usr/bin/id -u "${loggedInUser}" 2>/dev/null || echo "")
    if [ -n "${uid}" ]; then
        log "Utilisateur connecté : ${loggedInUser} (uid=${uid})"
        # bootout d'abord (au cas où une ancienne version traînait), puis bootstrap
        /bin/launchctl bootout "gui/${uid}" "${LAUNCH_AGENT}" 2>/dev/null || true
        if /bin/launchctl bootstrap "gui/${uid}" "${LAUNCH_AGENT}" 2>/dev/null; then
            log "LaunchAgent chargé pour ${loggedInUser}"
        else
            log "ATTENTION : bootstrap du LaunchAgent échoué — sera chargé au prochain login"
        fi
    fi
else
    log "Aucun utilisateur connecté — LaunchAgent sera chargé au prochain login"
fi

log "=== DesktopprManage install terminé ==="
exit 0
