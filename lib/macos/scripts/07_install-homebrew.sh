#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/fleet-install-homebrew.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Fleet Self-service: installation de Homebrew ==="
date

ARCH="$(/usr/bin/uname -m)"

if [ "$ARCH" = "arm64" ]; then
  HOMEBREW_PREFIX="/opt/homebrew"
else
  HOMEBREW_PREFIX="/usr/local"
fi

BREW_BIN="$HOMEBREW_PREFIX/bin/brew"

echo "Architecture détectée : $ARCH"
echo "Préfixe Homebrew attendu : $HOMEBREW_PREFIX"

if [ -x "$BREW_BIN" ]; then
  echo "OK: Homebrew est déjà installé."
  "$BREW_BIN" --version
  exit 0
fi

echo "Homebrew absent. Installation..."

NONINTERACTIVE=1 /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

if [ -x "$BREW_BIN" ]; then
  echo "OK: Homebrew installé."
  "$BREW_BIN" --version
else
  echo "ERREUR: Homebrew non trouvé après installation : $BREW_BIN"
  exit 1
fi

echo "=== Terminé ==="
date

exit 0