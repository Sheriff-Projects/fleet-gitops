#!/bin/bash

WALLPAPER_FOLDER="/Users/Shared/Wallpapers_SP"
WALLPAPER_FILE="${WALLPAPER_FOLDER}/Wallpaper_Retina_Black_SHERIFF_PROJECTS.jpg"
USER_PICTURE="${WALLPAPER_FOLDER}/sheriff_projects.jpg"
FLAG="/Library/Application Support/Sheriff Projects/post_enrollment_done"
LOG="/var/log/post-enrollment.log"
CURRENT_USER=$(stat -f "%Su" /dev/console)


log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

# Si déjà exécuté, on sort proprement
if [ -f "$FLAG" ]; then
  exit 0
fi

# Si aucun vrai utilisateur n'est connecté, on quitte en erreur
# pour laisser la policy retenter plus tard.

if [ "$CURRENT_USER" = "root" ] || [ "$CURRENT_USER" = "_mbsetupuser" ] || [ -z "$CURRENT_USER" ]; then
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Dark Mode
# ---------------------------------------------------------------------------
if [ -x /usr/local/bin/dark-mode ]; then
  logger -t "$LOG" "Activation Dark Mode pour ${CURRENT_USER}"

sudo -u "${CURRENT_USER}" /usr/local/bin/dark-mode

else
  logger -t "$LOGG" "WARNING: dark-mode absent, skip"
fi

# ---------------------------------------------------------------------------
# 2. Photo de profil de l'utilisateur
# ---------------------------------------------------------------------------

if [ -f "${USER_PICTURE}" ]; then

  logger -t "$LOG" "Import de la photo de profil pour ${CURRENT_USER}"

  dscl . delete "/Users/${CURRENT_USER}" Picture 2>/dev/null || true
  dscl . delete "/Users/${CURRENT_USER}" JPEGPhoto 2>/dev/null || true

  PICTURE_IMPORT="/Library/Caches/${CURRENT_USER}.picture.dsimport"
  {
    printf '0x0A 0x5C 0x3A 0x2C dsRecTypeStandard:Users 2 dsAttrTypeStandard:RecordName externalbinary:dsAttrTypeStandard:JPEGPhoto\n'
    printf '%s:%s\n' "${CURRENT_USER}" "${USER_PICTURE}"
  } > "${PICTURE_IMPORT}"

  dsimport "${PICTURE_IMPORT}" /Local/Default M || true
  rm -f "${PICTURE_IMPORT}"
else
  logger -t "$LOG" "WARNING: photo de profil absente, skip"
fi

# ---------------------------------------------------------------------------
# 3. Wallpaper : ajout du dossier dans les prefs Fond d'écran
# ---------------------------------------------------------------------------

if [ -d "${WALLPAPER_FOLDER}" ] && [ -x /usr/local/bin/wallpaper-folder ]; then

  logger -t "$LOG" "Ajout du dossier wallpaper aux prefs de ${CURRENT_USER}"

sudo -u "${CURRENT_USER}" /usr/local/bin/wallpaper-folder add "${WALLPAPER_FOLDER}"
sudo -u "${CURRENT_USER}" /usr/bin/killall cfprefsd
sudo -u "${CURRENT_USER}" /usr/bin/killall WallpaperAgent

else
  logger -t "$LOG" "WARNING: wallpaper-folder ou dossier wallpapers absent, skip"
fi

# ---------------------------------------------------------------------------
# 2. Wallpaper : application du fond d'écran via desktoppr
# ---------------------------------------------------------------------------

if [ -f "${WALLPAPER_FILE}" ] && [ -x /usr/local/bin/desktoppr ]; then

  logger -t "$LOG" "Application du wallpaper pour ${CURRENT_USER}"

sudo -u "${CURRENT_USER}" /usr/local/bin/desktoppr "${WALLPAPER_FILE}"

else
  logger -t "$LOG" "WARN: desktoppr ou wallpaper.jpg absent, skip"
fi

# Marqueur d'exécution
mkdir -p "/Library/Application Support/Sheriff Projects"
touch "$FLAG"

logger -t "$LOG" "Installation du système d'onboarding terminée"

exit 0