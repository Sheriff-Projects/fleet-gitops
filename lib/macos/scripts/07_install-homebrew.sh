#!/bin/bash
# install_homebrew.sh
#
# Installation silencieuse de Homebrew pour Fleet MDM.
#
# Particularités :
#   - Détecte l'architecture (Intel /usr/local vs Apple Silicon /opt/homebrew)
#   - Tourne en root (lancé par Fleet) mais Homebrew DOIT appartenir à l'user
#     local, donc on bascule en contexte user pour exécuter l'installer
#   - NONINTERACTIVE=1 évite tout prompt
#   - Idempotent : si Homebrew est déjà là, on ne fait rien (et exit 0)
#   - Ajoute Homebrew au PATH du shell de l'user
#
# Logs : /var/log/homebrew_install.log

set -uo pipefail

LOG="/var/log/homebrew_install.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Homebrew install started ==="

# -------------------------------------------------------------------------
# 1. Détection de l'architecture et du chemin Homebrew
# -------------------------------------------------------------------------
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
    log "Architecture détectée : Apple Silicon (arm64)"
else
    BREW_PREFIX="/usr/local"
    log "Architecture détectée : Intel ($ARCH)"
fi
BREW_BIN="$BREW_PREFIX/bin/brew"

# -------------------------------------------------------------------------
# 2. Skip si déjà installé
# -------------------------------------------------------------------------
if [ -x "$BREW_BIN" ]; then
    BREW_VERSION=$("$BREW_BIN" --version 2>/dev/null | head -1 || echo "unknown")
    log "Homebrew déjà installé : $BREW_VERSION → skip"
    log "=== Homebrew install: nothing to do ==="
    exit 0
fi

# -------------------------------------------------------------------------
# 3. Détection de l'user GUI (Homebrew DOIT appartenir à un user, pas root)
# -------------------------------------------------------------------------
CONSOLE_USER=$(stat -f%Su /dev/console)

if [ -z "$CONSOLE_USER" ] \
   || [ "$CONSOLE_USER" = "root" ] \
   || [ "$CONSOLE_USER" = "_mbsetupuser" ] \
   || [ "$CONSOLE_USER" = "loginwindow" ]; then
    log "[ERROR] Pas d'user GUI connecté ($CONSOLE_USER)"
    log "Homebrew nécessite un user pour s'installer, retry au prochain cycle"
    exit 1
fi

CONSOLE_UID=$(id -u "$CONSOLE_USER")
log "User GUI : $CONSOLE_USER (UID $CONSOLE_UID)"

# -------------------------------------------------------------------------
# 4. Vérifier les Command Line Tools (prérequis Homebrew)
# -------------------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
    log "Command Line Tools absents, installation..."
    # Trick standard : créer le placeholder qui débloque l'install non-interactif
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    # Trouver le package CLT disponible via softwareupdate
    CLT_PKG=$(softwareupdate -l 2>/dev/null | \
        grep -B 1 -E "Command Line.*Tools" | \
        awk -F"*" '/^ *\\*/ {print $2}' | \
        sed 's/^ Label: //' | \
        sort -V | tail -1)

    if [ -n "$CLT_PKG" ]; then
        log "Installation CLT package : $CLT_PKG"
        softwareupdate -i "$CLT_PKG" --verbose >> "$LOG" 2>&1 || true
    else
        log "[WARN] Impossible de trouver CLT via softwareupdate"
        log "  Le user devra peut-être installer Xcode CLT manuellement"
        log "  via : xcode-select --install"
    fi

    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

    # Re-vérifier
    if ! xcode-select -p >/dev/null 2>&1; then
        log "[ERROR] Command Line Tools toujours absents après installation"
        exit 1
    fi
fi

CLT_PATH=$(xcode-select -p)
log "Command Line Tools : $CLT_PATH"

# -------------------------------------------------------------------------
# 5. Lancer l'installer Homebrew en contexte user
# -------------------------------------------------------------------------
log "Téléchargement et installation de Homebrew (peut prendre 2-5 minutes)..."

# Helper pour exécuter en contexte user
run_as_user() {
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" "$@"
}

# NONINTERACTIVE=1     → pas de prompts (sudo, Enter to continue, etc.)
# CI=1                 → mode non-interactif renforcé
# HOMEBREW_NO_ANALYTICS=1 → pas d'analytics par défaut (respect vie privée user)
INSTALL_CMD='NONINTERACTIVE=1 CI=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

run_as_user /bin/bash -c "$INSTALL_CMD" >> "$LOG" 2>&1 || {
    log "[ERROR] Installer Homebrew a échoué"
    log "  Voir détails ci-dessus dans le log"
    exit 1
}

# -------------------------------------------------------------------------
# 6. Vérifier que brew est utilisable
# -------------------------------------------------------------------------
if [ ! -x "$BREW_BIN" ]; then
    log "[ERROR] brew binary non trouvé à $BREW_BIN après installation"
    exit 1
fi

BREW_VERSION=$(run_as_user "$BREW_BIN" --version 2>/dev/null | head -1)
log "Homebrew installé : $BREW_VERSION"

# -------------------------------------------------------------------------
# 7. Configurer le shell de l'user (PATH)
# -------------------------------------------------------------------------
# Sur Apple Silicon, /opt/homebrew/bin n'est PAS dans le PATH par défaut.
# On ajoute la ligne "eval $(brew shellenv)" dans les rc files de l'user.
USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
SHELLENV_LINE="eval \"\$(${BREW_BIN} shellenv)\""

add_to_rc() {
    local rc_file="$1"
    # Crée le fichier s'il n'existe pas
    if [ ! -f "$rc_file" ]; then
        run_as_user touch "$rc_file"
    fi
    # Ajoute la ligne seulement si elle n'est pas déjà là
    if ! grep -qF "brew shellenv" "$rc_file" 2>/dev/null; then
        log "Ajout de brew shellenv à $rc_file"
        echo "$SHELLENV_LINE" | run_as_user tee -a "$rc_file" >/dev/null
    fi
}

# zsh est le shell par défaut depuis macOS Catalina
add_to_rc "$USER_HOME/.zprofile"
# Au cas où l'user utilise bash
add_to_rc "$USER_HOME/.bash_profile"

# -------------------------------------------------------------------------
# 8. Update + cleanup initial (optionnel mais propre)
# -------------------------------------------------------------------------
log "Lancement de brew update..."
run_as_user "$BREW_BIN" update >> "$LOG" 2>&1 || {
    log "[WARN] brew update a échoué (non-bloquant)"
}

log "=== Homebrew install successful ==="
log "User : $CONSOLE_USER"
log "Path : $BREW_PREFIX"
log "Version : $BREW_VERSION"

exit 0