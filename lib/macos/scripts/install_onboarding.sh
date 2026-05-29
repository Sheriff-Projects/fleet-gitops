#!/bin/bash
#
# install_onboarding.sh — Installateur du LaunchDaemon Sheriff Projects
#
# Ce script est exécuté UNE SEULE FOIS par Fleet (via policy + run_script ou
# via setup_experience.macos_script). Il pose deux artefacts sur le Mac :
#
#   1. /usr/local/sheriffprojects/onboarding_once.sh
#      → Le script d'onboarding lui-même (wallpaper, dark mode, photo de profil)
#
#   2. /Library/LaunchDaemons/com.sheriffprojects.onboarding.plist
#      → Le LaunchDaemon qui le déclenche au boot et après chaque login
#
# Puis charge le LaunchDaemon dans launchd. À partir de là, la mécanique
# tourne toute seule : le daemon retry toutes les 30 secondes tant qu'aucun
# user GUI n'est connecté. Dès qu'un user se log, le script s'exécute, fait
# son boulot, pose le sentinel /var/db/.sheriff_onboarding_done, et le daemon
# arrête de boucler (KeepAlive.SuccessfulExit=false).
#
# Idempotent : si tout est déjà en place, le script écrase les fichiers existants
# (utile pour pousser une nouvelle version) puis recharge le daemon proprement.
#

set -euo pipefail

LOG_TAG="fleet-onboarding-install"
SCRIPT_DIR="/usr/local/sheriffprojects"
SCRIPT_PATH="${SCRIPT_DIR}/onboarding_once.sh"
DAEMON_LABEL="com.sheriffprojects.onboarding"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

logger -t "$LOG_TAG" "Installation du système d'onboarding Sheriff Projects"

# ===========================================================================
# 1. Créer le dossier et écrire onboarding_once.sh
# ===========================================================================
mkdir -p "${SCRIPT_DIR}"
chmod 755 "${SCRIPT_DIR}"
chown root:wheel "${SCRIPT_DIR}"

cat > "${SCRIPT_PATH}" << 'ONBOARDING_EOF'
#!/bin/bash
#
# onboarding_once.sh — Onboarding Sheriff Projects pour Mac (1 user / Mac)
#
# Idempotent : ne s'exécute qu'une fois grâce au sentinel.
# Re-déclenchement manuel : sudo rm /var/db/.sheriff_onboarding_done
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

# Récupération du user GUI
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

# Helper : exécute une commande dans le contexte de l'user GUI
run_as_user() {
  /bin/launchctl asuser "${CONSOLE_UID}" /usr/bin/sudo -u "${CONSOLE_USER}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Wallpaper : ajout du dossier dans les prefs Fond d'écran
# ---------------------------------------------------------------------------
if [ -d "${WALLPAPER_FOLDER}" ] && [ -x /usr/local/bin/wallpaper-folder ]; then
  logger -t "$LOG_TAG" "Ajout du dossier wallpaper aux prefs de ${CONSOLE_USER}"
  run_as_user /usr/local/bin/wallpaper-folder add "${WALLPAPER_FOLDER}" --verbose || true
  run_as_user /usr/bin/killall cfprefsd 2>/dev/null || true
  run_as_user /usr/bin/killall WallpaperAgent 2>/dev/null || true
else
  logger -t "$LOG_TAG" "WARN: wallpaper-folder ou dossier wallpapers absent, skip"
fi

# ---------------------------------------------------------------------------
# 2. Wallpaper : application du fond d'écran via desktoppr
# ---------------------------------------------------------------------------
if [ -f "${WALLPAPER_FILE}" ] && [ -x /usr/local/bin/desktoppr ]; then
  logger -t "$LOG_TAG" "Application du wallpaper pour ${CONSOLE_USER}"
  run_as_user /usr/local/bin/desktoppr "${WALLPAPER_FILE}" || true
else
  logger -t "$LOG_TAG" "WARN: desktoppr ou wallpaper.jpg absent, skip"
fi

# ---------------------------------------------------------------------------
# 3. Dark Mode
# ---------------------------------------------------------------------------
if [ -x /usr/local/bin/dark-mode ]; then
  logger -t "$LOG_TAG" "Activation Dark Mode pour ${CONSOLE_USER}"
  run_as_user /usr/local/bin/dark-mode || true
else
  logger -t "$LOG_TAG" "WARN: dark-mode absent, skip"
fi

# ---------------------------------------------------------------------------
# 4. Photo de profil de l'utilisateur
# ---------------------------------------------------------------------------
if [ -f "${USER_PICTURE}" ]; then
  logger -t "$LOG_TAG" "Import de la photo de profil pour ${CONSOLE_USER}"

  dscl . delete "/Users/${CONSOLE_USER}" Picture 2>/dev/null || true
  dscl . delete "/Users/${CONSOLE_USER}" JPEGPhoto 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# Pose du sentinel — DERNIÈRE étape
# ---------------------------------------------------------------------------
touch "${SENTINEL}"
chmod 644 "${SENTINEL}"
chown root:wheel "${SENTINEL}"

logger -t "$LOG_TAG" "Onboarding terminé pour ${CONSOLE_USER}, sentinel posé"
exit 0
ONBOARDING_EOF

chmod 755 "${SCRIPT_PATH}"
chown root:wheel "${SCRIPT_PATH}"
logger -t "$LOG_TAG" "Script onboarding_once.sh écrit dans ${SCRIPT_PATH}"

# ===========================================================================
# 2. Écrire le LaunchDaemon plist
# ===========================================================================
cat > "${DAEMON_PLIST}" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${DAEMON_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
    </array>

    <!-- Lance le script au chargement du daemon (au boot, ou ici après install) -->
    <key>RunAtLoad</key>
    <true/>

    <!-- KeepAlive avec retry si le script sort en erreur (exit != 0).
         Quand un user GUI n'est pas encore connecté, le script sort en exit 1
         et le daemon retentera après ThrottleInterval. Quand le script
         réussit (exit 0), KeepAlive.SuccessfulExit=false fait que le daemon
         s'arrête définitivement. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <!-- Attendre 30 secondes entre chaque tentative -->
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <!-- Logs stdout/stderr pour debug -->
    <key>StandardOutPath</key>
    <string>/var/log/sheriff_onboarding.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/sheriff_onboarding.log</string>
</dict>
</plist>
PLIST_EOF

chmod 644 "${DAEMON_PLIST}"
chown root:wheel "${DAEMON_PLIST}"
logger -t "$LOG_TAG" "LaunchDaemon plist écrit dans ${DAEMON_PLIST}"

# ===========================================================================
# 3. Charger (ou recharger) le LaunchDaemon
# ===========================================================================

# Si le daemon est déjà chargé (cas d'une nouvelle install), on le décharge d'abord
if launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
  logger -t "$LOG_TAG" "Daemon déjà chargé, bootout pour reload"
  launchctl bootout system "${DAEMON_PLIST}" 2>/dev/null || true
fi

# Charger le daemon → ça déclenche RunAtLoad → le script tourne
launchctl bootstrap system "${DAEMON_PLIST}"
logger -t "$LOG_TAG" "LaunchDaemon ${DAEMON_LABEL} chargé"

logger -t "$LOG_TAG" "Installation du système d'onboarding terminée"
exit 0