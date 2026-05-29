#!/bin/bash
#
# Install Volume Licence Microsoft 365
# Fleet télécharge le .pkg depuis l'URL définie dans volume_licence_microsoft_365.yml
# et expose son chemin local via $INSTALLER_PATH.
#

set -eu

LOG_TAG="Volume-Licence-m365"

logger -t "$LOG_TAG" "Démarrage de l'installation Volume Licence Microsoft 365"
logger -t "$LOG_TAG" "Installer path: ${INSTALLER_PATH}"

# Vérifie que le fichier existe
if [ ! -f "${INSTALLER_PATH}" ]; then
  logger -t "$LOG_TAG" "ERREUR: installer introuvable à ${INSTALLER_PATH}"
  echo "Installer not found at ${INSTALLER_PATH}" >&2
  exit 1
fi

# Lance l'installation système (target / = volume de boot)
# /usr/sbin/installer est l'outil natif macOS, signé par Apple
installer -pkg "${INSTALLER_PATH}" -target /
INSTALL_EXIT=$?

if [ $INSTALL_EXIT -ne 0 ]; then
  logger -t "$LOG_TAG" "ERREUR: installation échouée (exit $INSTALL_EXIT)"
  exit $INSTALL_EXIT
fi

logger -t "$LOG_TAG" "Installation VMicrosoft 365 réussie"
exit 0
