#!/bin/bash
#
# Désinstallation complète de Microsoft 365 sur macOS
# Suit la procédure officielle Microsoft :
# https://learn.microsoft.com/en-us/microsoft-365-apps/mac/uninstall-office-for-mac
#

set -u

LOG_TAG="fleet-uninstall-m365"

logger -t "$LOG_TAG" "Démarrage de la désinstallation Microsoft 365"

# ---------------------------------------------------------------------------
# 1. Quitter proprement les apps Office si elles sont ouvertes
# ---------------------------------------------------------------------------
for app in "Microsoft Word" "Microsoft Excel" "Microsoft PowerPoint" \
           "Microsoft Outlook" "Microsoft OneNote" "OneDrive" \
           "Microsoft Teams" "Microsoft AutoUpdate"; do
  osascript -e "tell application \"${app}\" to quit" 2>/dev/null || true
done

sleep 2

# ---------------------------------------------------------------------------
# 2. Supprimer les bundles d'application
# ---------------------------------------------------------------------------
for app_path in \
  "/Applications/Microsoft Word.app" \
  "/Applications/Microsoft Excel.app" \
  "/Applications/Microsoft PowerPoint.app" \
  "/Applications/Microsoft Outlook.app" \
  "/Applications/Microsoft OneNote.app" \
  "/Applications/OneDrive.app" \
  "/Applications/Microsoft Teams.app" \
  "/Applications/Microsoft Teams classic.app"; do
  if [ -e "${app_path}" ]; then
    rm -rf "${app_path}"
    logger -t "$LOG_TAG" "Supprimé : ${app_path}"
  fi
done

# ---------------------------------------------------------------------------
# 3. Nettoyage des fichiers système (Microsoft AutoUpdate, helpers, daemons)
# ---------------------------------------------------------------------------
rm -rf "/Library/Application Support/Microsoft/MAU2.0" 2>/dev/null || true
rm -rf "/Library/Application Support/Microsoft AU Daemon" 2>/dev/null || true
rm -rf "/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper" 2>/dev/null || true
rm -rf "/Library/LaunchAgents/com.microsoft.update.agent.plist" 2>/dev/null || true
rm -rf "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist" 2>/dev/null || true
rm -rf "/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist" 2>/dev/null || true
rm -rf "/Library/Logs/Microsoft" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Supprimer les receipts pkgutil (pour que pre_install_query retourne 0)
# ---------------------------------------------------------------------------
pkgutil --pkgs | grep -iE "^com\.microsoft\." | while read -r pkg_id; do
  pkgutil --forget "${pkg_id}" 2>/dev/null || true
  logger -t "$LOG_TAG" "Receipt oublié : ${pkg_id}"
done

# ---------------------------------------------------------------------------
# 5. Nettoyage des données utilisateur (utilisateur connecté à la console)
#    /!\ Supprime les préférences et caches Office de l'utilisateur courant.
#    Les documents dans Documents/ ne sont PAS touchés.
# ---------------------------------------------------------------------------
CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")

if [ -n "${CONSOLE_USER}" ] && [ "${CONSOLE_USER}" != "root" ] && [ "${CONSOLE_USER}" != "loginwindow" ]; then
  USER_HOME=$(dscl . -read /Users/"${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')

  if [ -n "${USER_HOME}" ] && [ -d "${USER_HOME}" ]; then
    logger -t "$LOG_TAG" "Nettoyage des fichiers utilisateur pour ${CONSOLE_USER}"

    # Containers (sandbox des apps Office)
    rm -rf "${USER_HOME}/Library/Containers/com.microsoft."* 2>/dev/null || true

    # Group containers (données partagées entre apps Office, ex. profils Outlook)
    rm -rf "${USER_HOME}/Library/Group Containers/UBF8T346G9."* 2>/dev/null || true

    # Préférences et caches
    rm -rf "${USER_HOME}/Library/Application Support/Microsoft" 2>/dev/null || true
    rm -rf "${USER_HOME}/Library/Caches/com.microsoft."* 2>/dev/null || true
    rm -f  "${USER_HOME}/Library/Preferences/com.microsoft."*.plist 2>/dev/null || true
  fi
fi

logger -t "$LOG_TAG" "Désinstallation Microsoft 365 terminée"
exit 0
