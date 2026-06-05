#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/fleet-install-dev-tools.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Fleet Self-service: Command Line Tools + Rosetta ==="
date

CLT_PATH="/Library/Developer/CommandLineTools"
CLT_RECEIPT="com.apple.pkg.CLTools_Executables"
SENTINEL="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

ARCH="$(/usr/bin/uname -m)"

is_clt_installed() {
  /usr/sbin/pkgutil --pkg-info "$CLT_RECEIPT" >/dev/null 2>&1 && [ -d "$CLT_PATH" ]
}

show_clt_version() {
  if /usr/sbin/pkgutil --pkg-info "$CLT_RECEIPT" >/dev/null 2>&1; then
    /usr/sbin/pkgutil --pkg-info "$CLT_RECEIPT" | grep -E "package-id|version|install-time" || true
  else
    echo "Command Line Tools non installés."
  fi
}

find_clt_update_label() {
  /usr/sbin/softwareupdate --list 2>&1 | awk -F'* Label: ' '
    /Label: Command Line Tools/ && $2 !~ /beta|Beta/ { print $2 }
  ' | tail -n 1
}

install_or_update_clt() {
  echo "--- Command Line Tools ---"

  echo "État avant :"
  show_clt_version

  touch "$SENTINEL"
  trap 'rm -f "$SENTINEL"' EXIT

  LABEL="$(find_clt_update_label || true)"

  if [ -z "${LABEL:-}" ]; then
    echo "Aucune installation/mise à jour Command Line Tools disponible via softwareupdate."
  else
    echo "Installation/mise à jour : $LABEL"
    /usr/sbin/softwareupdate --install "$LABEL" --verbose
  fi

  if [ -d "$CLT_PATH" ]; then
    /usr/bin/xcode-select --switch "$CLT_PATH" || true
  fi

  echo "État après :"
  show_clt_version

  if is_clt_installed; then
    echo "OK: Command Line Tools installés ou à jour."
  else
    echo "ATTENTION: Command Line Tools non détectés après exécution."
  fi
}

is_rosetta_installed() {
  /usr/bin/pgrep oahd >/dev/null 2>&1 && return 0

  if [ -f "/Library/Apple/System/Library/LaunchDaemons/com.apple.oahd.plist" ]; then
    return 0
  fi

  return 1
}

install_rosetta() {
  echo "--- Rosetta ---"

  if [ "$ARCH" != "arm64" ]; then
    echo "Mac Intel détecté ($ARCH) : Rosetta ignoré."
    return 0
  fi

  if is_rosetta_installed; then
    echo "OK: Rosetta est déjà installé."
    return 0
  fi

  echo "Mac Apple Silicon détecté : installation de Rosetta..."
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license

  if is_rosetta_installed; then
    echo "OK: Rosetta installé."
  else
    echo "ERREUR: Rosetta non détecté après installation."
    return 1
  fi
}

install_or_update_clt
install_rosetta

echo "=== Terminé ==="
date

exit 0