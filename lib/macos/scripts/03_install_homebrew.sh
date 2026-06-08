#!/bin/bash
# install_homebrew.sh (Sheriff Projects — version service admin)
#
# Installe Homebrew dans le contexte du compte de service sp-installer
# (admin caché créé par create_service_admin.sh).
#
# Conséquence : l'utilisateur final (samir.ouari, etc.) reste STANDARD.
# /opt/homebrew/ (ou /usr/local sur Intel) appartient à sp-installer.
# Les standard users peuvent LIRE brew (brew list, brew search, brew info)
# mais ne peuvent PAS installer de software via brew install (refusé par
# manque de droits sur /opt/homebrew/ et /Applications/).
#
# Logs : /var/log/homebrew_install.log

set -uo pipefail

# ===========================================================================
# CONFIG
# ===========================================================================
SERVICE_USER="sp-installer"

LOG="/var/log/homebrew_install.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Homebrew install started (via $SERVICE_USER) ==="

# Fix le cwd
cd /tmp || cd /

# -------------------------------------------------------------------------
# 1. Détection de l'architecture
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
    BREW_OWNER=$(stat -f%Su "$BREW_PREFIX")
    log "Homebrew déjà installé : $BREW_VERSION"
    log "  Propriétaire : $BREW_OWNER"

    if [ "$BREW_OWNER" != "$SERVICE_USER" ]; then
        log "[WARN] Homebrew n'appartient pas à $SERVICE_USER ($BREW_OWNER)"
        log "Si tu veux corriger : sudo chown -R $SERVICE_USER:admin $BREW_PREFIX"
    fi

    log "=== Homebrew install: nothing to do ==="
    exit 0
fi

# -------------------------------------------------------------------------
# 3. Vérifier que sp-installer existe (créé par create_service_admin.sh)
# -------------------------------------------------------------------------
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "[ERROR] Le compte $SERVICE_USER n'existe pas"
    log "Déploie d'abord create_service_admin.sh avant Homebrew."
    exit 1
fi

if ! dseditgroup -o checkmember -m "$SERVICE_USER" admin >/dev/null 2>&1; then
    log "[ERROR] $SERVICE_USER n'est pas admin"
    log "Re-déploie create_service_admin.sh pour corriger."
    exit 1
fi
log "$SERVICE_USER est admin ✓"

# -------------------------------------------------------------------------
# 4. Vérifier les Command Line Tools
# -------------------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
    log "[ERROR] Command Line Tools absents — déploie install_xcode_clt.sh d'abord"
    exit 1
fi
log "Command Line Tools : $(xcode-select -p)"

# -------------------------------------------------------------------------
# 5. Lancer l'installer Homebrew via sp-installer
# -------------------------------------------------------------------------
# Comme sp-installer a NOPASSWD via /etc/sudoers.d/, l'installer Homebrew
# qui fait sudo -v interne passe sans prompt.
log "Téléchargement et installation de Homebrew (peut prendre 2-5 minutes)..."

SERVICE_HOME=$(dscl . -read "/Users/$SERVICE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "$SERVICE_HOME" ] && SERVICE_HOME="/var/$SERVICE_USER"

# Crée le HOME si pas déjà
mkdir -p "$SERVICE_HOME"
chown "${SERVICE_USER}:admin" "$SERVICE_HOME"
chmod 750 "$SERVICE_HOME"

INSTALL_CMD="cd \"$SERVICE_HOME\" && NONINTERACTIVE=1 CI=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

# Note : on ne passe PAS par launchctl asuser parce que sp-installer n'a
# pas de session GUI (et ne devrait jamais en avoir). On utilise directement
# sudo -u avec -H pour fixer HOME proprement.
if ! sudo -u "$SERVICE_USER" -H /bin/bash -c "$INSTALL_CMD" >> "$LOG" 2>&1; then
    log "[ERROR] Installer Homebrew a échoué"
    log "  Voir détails ci-dessus dans le log"
    exit 1
fi

# -------------------------------------------------------------------------
# 6. Vérifier que brew est utilisable
# -------------------------------------------------------------------------
if [ ! -x "$BREW_BIN" ]; then
    log "[ERROR] brew binary non trouvé à $BREW_BIN après installation"
    exit 1
fi

BREW_VERSION=$(sudo -u "$SERVICE_USER" -H "$BREW_BIN" --version 2>/dev/null | head -1)
log "Homebrew installé : $BREW_VERSION"

# Vérifie l'ownership
BREW_OWNER=$(stat -f%Su "$BREW_PREFIX")
log "Propriétaire $BREW_PREFIX : $BREW_OWNER"

# -------------------------------------------------------------------------
# 7. Configurer le PATH pour TOUS les users (système-wide)
# -------------------------------------------------------------------------
# Pour que tous les users (samir.ouari + futurs users) puissent utiliser
# brew read-only (brew list, search, info), on ajoute le PATH dans
# /etc/zshrc et /etc/bashrc (modifs système, pas user).
SHELLENV_LINE="eval \"\$(${BREW_BIN} shellenv)\""

add_to_system_rc() {
    local rc_file="$1"
    if [ ! -f "$rc_file" ]; then
        touch "$rc_file"
    fi
    if ! grep -qF "brew shellenv" "$rc_file" 2>/dev/null; then
        log "Ajout brew shellenv à $rc_file (system-wide)"
        echo "" >> "$rc_file"
        echo "# Homebrew (added by Sheriff Projects)" >> "$rc_file"
        echo "$SHELLENV_LINE" >> "$rc_file"
    fi
}

# zsh est le shell par défaut depuis macOS Catalina
add_to_system_rc "/etc/zshrc"
add_to_system_rc "/etc/bashrc"

# -------------------------------------------------------------------------
# 8. brew update initial (en tant que sp-installer)
# -------------------------------------------------------------------------
log "Lancement de brew update..."
sudo -u "$SERVICE_USER" -H "$BREW_BIN" install cask >> "$LOG" 2>&1 || {
    log "[WARN] cask install a échoué"
}
sudo -u "$SERVICE_USER" -H "$BREW_BIN" update >> "$LOG" 2>&1 || {
    log "[WARN] brew update a échoué (non-bloquant)"
}

log "=== Homebrew install successful ==="
log "Owner   : $SERVICE_USER"
log "Path    : $BREW_PREFIX"
log "Version : $BREW_VERSION"

exit 0