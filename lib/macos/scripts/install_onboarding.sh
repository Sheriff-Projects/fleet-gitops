#!/bin/bash
#
# onboarding_once.sh — Onboarding Sheriff Projects pour Mac (1 user / Mac)
#
# Idempotent : ne s'exécute qu'une fois grâce au sentinel /var/db/.sheriff_onboarding_done.
# Si aucun user GUI n'est connecté, sort en exit 1 pour que Fleet (ou le
# LaunchDaemon) le relance au prochain cycle.
#
# Actions :
#   1. Ajout du dossier Sheriff Projects aux wallpapers de l'user (wallpaper-folder)
#   2. Application du wallpaper par défaut (desktoppr)
#   3. Activation Dark Mode (dark-mode)
#   4. Import de la photo de profil de l'user (dscl + dsimport)
#
# Re-déclenchement manuel :
#   sudo rm /var/db/.sheriff_onboarding_done
#

set -eu

LOG_TAG="fleet-onboarding"
SENTINEL="/var/db/.sheriff_onboarding_done"

WALLPAPER_FOLDER="/Users/Shared/sp_wallpapers"
WALLPAPER_FILE="${WALLPAPER_FOLDER}/Wallpaper_Retina_Black_SHERIFF_PROJECTS.jpg"
USER_PICTURE="${WALLPAPER_FOLDER}/sheriff_projects.jpg"

# ---------------------------------------------------------------------------
# Sortie immédiate si déjà exécuté sur cette machine
# ---------------------------------------------------------------------------
if [ -f "${SENTINEL}" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Récupération du user connecté en GUI
# ---------------------------------------------------------------------------
CONSOLE_USER=$(stat -f%Su /dev/console)

if [ -z "${CONSOLE_USER}" ] \
   || [ "${CONSOLE_USER}" = "root" ] \
   || [ "${CONSOLE_USER}" = "_mbsetupuser" ] \
   || [ "${CONSOLE_USER}" = "loginwindow" ]; then
  logger -t "$LOG_TAG" "Pas d'user GUI connecté ($CONSOLE_USER), retry au prochain cycle"
  exit 1
fi

CONSOLE_UID=$(id -u "${CONSOLE_USER}")
logger -t "$LOG_TAG" "Démarrage onboarding pour ${CONSOLE_USER} (UID ${CONSOLE_UID})"

# ---------------------------------------------------------------------------
# Helper : exécute une commande dans le contexte de l'user GUI
# ---------------------------------------------------------------------------
run_as_user() {
  /bin/launchctl asuser "${CONSOLE_UID}" /usr/bin/sudo -u "${CONSOLE_USER}" "$@"
}

# ===========================================================================
# 3. Dark Mode
# ===========================================================================
if [ -x /usr/local/bin/dark-mode ]; then
  logger -t "$LOG_TAG" "Activation Dark Mode pour ${CONSOLE_USER}"
  run_as_user /usr/local/bin/dark-mode || true
else
  logger -t "$LOG_TAG" "WARN: dark-mode absent, skip"
fi

# ===========================================================================
# 1. Wallpaper : ajout du dossier dans les prefs Fond d'écran
# ===========================================================================
if [ -d "${WALLPAPER_FOLDER}" ] && [ -x /usr/local/bin/wallpaper-folder ]; then
  logger -t "$LOG_TAG" "Ajout du dossier wallpaper aux prefs de ${CONSOLE_USER}"
  run_as_user /usr/local/bin/wallpaper-folder add "${WALLPAPER_FOLDER}" --verbose || true
  run_as_user /usr/bin/killall cfprefsd 2>/dev/null || true
  run_as_user /usr/bin/killall WallpaperAgent 2>/dev/null || true
else
  logger -t "$LOG_TAG" "WARN: wallpaper-folder ou dossier wallpapers absent, skip"
fi

# ===========================================================================
# 2. Wallpaper : application du fond d'écran via desktoppr
# ===========================================================================
if [ -f "${WALLPAPER_FILE}" ] && [ -x /usr/local/bin/desktoppr ]; then
  logger -t "$LOG_TAG" "Application du wallpaper pour ${CONSOLE_USER}"
  run_as_user /usr/local/bin/desktoppr "${WALLPAPER_FILE}" || true
else
  logger -t "$LOG_TAG" "WARN: desktoppr ou wallpaper.jpg absent, skip"
fi



# ===========================================================================
# 4. Photo de profil de l'utilisateur
# ===========================================================================
if [ -f "${USER_PICTURE}" ]; then
  logger -t "$LOG_TAG" "Import de la photo de profil pour ${CONSOLE_USER}"

  # Nettoyer les anciens attributs picture
  dscl . delete "/Users/${CONSOLE_USER}" Picture 2>/dev/null || true
  dscl . delete "/Users/${CONSOLE_USER}" JPEGPhoto 2>/dev/null || true

  # Construire le fichier dsimport et l'importer
  PICTURE_IMPORT="/Library/Caches/${CONSOLE_USER}.picture.dsimport"
  {
    printf '0x0A 0x5C 0x3A 0x2C dsRecTypeStandard:Users 2 dsAttrTypeStandard:RecordName externalbinary:dsAttrTypeStandard:JPEGPhoto\n'
    printf '%s:%s\n' "${CONSOLE_USER}" "${USER_PICTURE}"
  } > "${PICTURE_IMPORT}"

  dsimport "${PICTURE_IMPORT}" /Local/Default M || true
  rm -f "${PICTURE_IMPORT}"
else
  logger -t "$LOG_TAG" "WARN: photo de profil absente, skip"
fi

# ===========================================================================
# Pose du sentinel — DERNIÈRE étape pour que le script soit re-tenté en cas
# d'erreur sur une étape précédente (set -e fera sortir avant le touch).
# ===========================================================================
touch "${SENTINEL}"
chmod 644 "${SENTINEL}"
chown root:wheel "${SENTINEL}"

logger -t "$LOG_TAG" "Onboarding terminé pour ${CONSOLE_USER}, sentinel posé"
exit 0