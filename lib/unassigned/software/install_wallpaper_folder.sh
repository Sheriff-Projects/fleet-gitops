#!/bin/sh
#
# Install script — WallpaperFolderManager + ajout du dossier sp_wallpapers
# https://github.com/bartreardon/WallpaperFolderManager
#
# Tourne en root via Fleet. $INSTALLER_PATH = chemin du .pkg fourni par Fleet.
#

set -u

LOG="/var/log/sp_wallpapers_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

WALLPAPER_FOLDER="/Users/Shared/sp_wallpapers"
WALLPAPER_BIN="/usr/local/bin/wallpaper-folder"

log "=== Install démarré ==="

# ---------------------------------------------------------------------------
# 1. Installation du pkg WallpaperFolderManager
# ---------------------------------------------------------------------------
if [ -z "${INSTALLER_PATH:-}" ] || [ ! -f "${INSTALLER_PATH}" ]; then
    log "ERREUR : INSTALLER_PATH non défini ou fichier introuvable"
    exit 1
fi

log "Installation du pkg : ${INSTALLER_PATH}"
if ! /usr/sbin/installer -pkg "${INSTALLER_PATH}" -target / >>"$LOG" 2>&1; then
    log "ERREUR : échec de l'installation du pkg"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Vérifications post-install
# ---------------------------------------------------------------------------
if [ ! -x "${WALLPAPER_BIN}" ]; then
    log "ERREUR : ${WALLPAPER_BIN} introuvable ou non exécutable"
    exit 1
fi

if [ ! -d "${WALLPAPER_FOLDER}" ]; then
    log "ERREUR : dossier de wallpapers introuvable : ${WALLPAPER_FOLDER}"
    log "         (le pkg sp_wallpapers doit être installé AVANT celui-ci)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Détecter l'utilisateur connecté à la console
# ---------------------------------------------------------------------------
loggedInUser=$(echo "show State:/Users/ConsoleUser" | /usr/sbin/scutil \
    | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')

if [ -z "${loggedInUser}" ]; then
    log "Aucun utilisateur connecté — l'ajout du dossier sera fait au prochain login"
    log "(via LaunchAgent si configuré, sinon manuellement)"
    exit 0
fi

uid=$(/usr/bin/id -u "${loggedInUser}" 2>/dev/null)
if [ -z "${uid}" ]; then
    log "ERREUR : impossible de récupérer l'UID de ${loggedInUser}"
    exit 1
fi

log "Utilisateur connecté : ${loggedInUser} (uid=${uid})"

# ---------------------------------------------------------------------------
# 4. Ajouter le dossier dans le contexte de l'utilisateur
# ---------------------------------------------------------------------------
log "Ajout du dossier ${WALLPAPER_FOLDER} aux préférences Wallpaper de ${loggedInUser}"

# launchctl asuser exécute la commande dans la session GUI de l'utilisateur
# → wallpaper-folder écrit dans les bonnes préférences
if /bin/launchctl asuser "${uid}" "${WALLPAPER_BIN}" add "${WALLPAPER_FOLDER}" --verbose >>"$LOG" 2>&1; then
    log "Dossier ajouté avec succès"
else
    log "ATTENTION : wallpaper-folder a renvoyé une erreur (voir log)"
fi

# ---------------------------------------------------------------------------
# 5. Recharger les agents dans le contexte de l'utilisateur
# ---------------------------------------------------------------------------
/bin/launchctl asuser "${uid}" /usr/bin/killall cfprefsd       2>/dev/null || true
/bin/launchctl asuser "${uid}" /usr/bin/killall WallpaperAgent 2>/dev/null || true

log "=== Install terminé ==="
exit 0