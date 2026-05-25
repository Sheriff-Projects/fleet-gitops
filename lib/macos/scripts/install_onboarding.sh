#!/bin/bash
#
# onboarding_once.sh — Onboarding Sheriff Projects pour Mac (1 user / Mac)
# Idempotent : ne s'exécute qu'une fois grâce au sentinel.
#

set -eu

LOG_TAG="fleet-onboarding"
SENTINEL="/var/db/.sheriff_onboarding_done"

WALLPAPER_FOLDER="/Users/Shared/Wallpapers_SP"
WALLPAPER_FILE="${WALLPAPER_FOLDER}/Wallpaper_Retina_Black_SHERIFF_PROJECTS.jpg"
USER_PICTURE="${WALLPAPER_FOLDER}/sheriff_projects.jpg"

# Sortie immédiate si déjà exécuté
if [ -f "${SENTINEL}" ]; then
  exit 0
fi

# Récupération du user connecté en GUI
CONSOLE_USER=$(stat -f%Su /dev/console)

if [ -z "${CONSOLE_USER}" ] \
   || [ "${CONSOLE_USER}" = "root" ] \
   || [ "${CONSOLE_USER}" = "_mbsetupuser" ] \
   || [ "${CONSOLE_USER}" = "loginwindow" ]; then
  logger -t "$LOG_TAG" "Pas d'user GUI connecté, retry au prochain cycle"
  exit 1
fi

CONSOLE_UID=$(id -u "${CONSOLE_USER}")
logger -t "$LOG_TAG" "Démarrage onboarding pour ${CONSOLE_USER}"

# Helper : exécute une commande en tant que l'user connecté
run_as_user() {
  /bin/launchctl asuser "${CONSOLE_UID}" /usr/bin/sudo -u "${CONSOLE_USER}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Wallpaper : ajout du dossier + sélection + dark mode
# ---------------------------------------------------------------------------
if [ -d "${WALLPAPER_FOLDER}" ] && [ -x /usr/local/bin/wallpaper-folder ]; then
  run_as_user /usr/local/bin/wallpaper-folder add "${WALLPAPER_FOLDER}" --verbose || true
  run_as_user /usr/bin/killall cfprefsd 2>/dev/null || true
  run_as_user /usr/bin/killall WallpaperAgent 2>/dev/null || true
fi

if [ -f "${WALLPAPER_FILE}" ] && [ -x /usr/local/bin/desktoppr ]; then
  run_as_user /usr/local/bin/desktoppr "${WALLPAPER_FILE}" || true
fi

if [ -x /usr/local/bin/dark-mode ]; then
  run_as_user /usr/local/bin/dark-mode || true
fi

# ---------------------------------------------------------------------------
# 2. Photo de profil de l'user
# ---------------------------------------------------------------------------
if [ -f "${USER_PICTURE}" ]; then
  dscl . delete "/Users/${CONSOLE_USER}" Picture 2>/dev/null || true
  dscl . delete "/Users/${CONSOLE_USER}" JPEGPhoto 2>/dev/null || true

  PICTURE_IMPORT="/Library/Caches/${CONSOLE_USER}.picture.dsimport"
  {
    printf '0x0A 0x5C 0x3A 0x2C dsRecTypeStandard:Users 2 dsAttrTypeStandard:RecordName externalbinary:dsAttrTypeStandard:JPEGPhoto\n'
    printf '%s:%s\n' "${CONSOLE_USER}" "${USER_PICTURE}"
  } > "${PICTURE_IMPORT}"

  dsimport "${PICTURE_IMPORT}" /Local/Default M || true
  rm -f "${PICTURE_IMPORT}"
fi

# ---------------------------------------------------------------------------
# Sentinel posé en dernier
# ---------------------------------------------------------------------------
touch "${SENTINEL}"
chown root:wheel "${SENTINEL}"

logger -t "$LOG_TAG" "Onboarding terminé pour ${CONSOLE_USER}"
exit 0