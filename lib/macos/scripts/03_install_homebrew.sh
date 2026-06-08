#!/bin/bash
# install_homebrew.sh (Sheriff Projects — version service admin)
#
# Installe Homebrew dans le contexte du compte de service sp-installer.
#
# Particularité Intel vs Apple Silicon :
#   - Apple Silicon : Homebrew dans /opt/homebrew (créé pour brew, libre)
#     → on peut faire chown -R /opt/homebrew sans souci
#   - Intel : Homebrew dans /usr/local (dossier système macOS, protégé SIP)
#     → on chown SEULEMENT les sous-dossiers gérés par brew, pas /usr/local lui-même
#
# Cask est intégré nativement à Homebrew. Pas besoin de l'installer séparément.
#
# Conséquence : l'utilisateur final (samir.ouari, etc.) reste STANDARD.
# Les standard users peuvent LIRE brew (brew list, search, info)
# mais ne peuvent PAS installer via brew install (refusé par manque de droits).
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

cd /tmp || cd /

# -------------------------------------------------------------------------
# 1. Détection de l'architecture
# -------------------------------------------------------------------------
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
    IS_INTEL=0
    log "Architecture détectée : Apple Silicon (arm64)"
else
    BREW_PREFIX="/usr/local"
    IS_INTEL=1
    log "Architecture détectée : Intel ($ARCH)"
fi
BREW_BIN="$BREW_PREFIX/bin/brew"

# -------------------------------------------------------------------------
# Helper : corrige l'ownership de Homebrew selon l'arch
# -------------------------------------------------------------------------
fix_brew_ownership() {
    if [ "$IS_INTEL" = "1" ]; then
        # Intel : on chown UNIQUEMENT les sous-dossiers brew, pas /usr/local
        log "Correction ownership (Intel : sous-dossiers brew uniquement)"
        local brew_subdirs=(
            "$BREW_PREFIX/Homebrew"
            "$BREW_PREFIX/Caskroom"
            "$BREW_PREFIX/Cellar"
            "$BREW_PREFIX/Frameworks"
            "$BREW_PREFIX/etc"
            "$BREW_PREFIX/include"
            "$BREW_PREFIX/lib"
            "$BREW_PREFIX/opt"
            "$BREW_PREFIX/sbin"
            "$BREW_PREFIX/share"
            "$BREW_PREFIX/var"
        )
        local failed=0
        for d in "${brew_subdirs[@]}"; do
            if [ -d "$d" ]; then
                if chown -R "${SERVICE_USER}:admin" "$d" 2>/dev/null; then
                    log "  ✓ $d"
                else
                    log "  ⚠ Impossible de chown $d (peut être OK si peu utilisé par brew)"
                    failed=$((failed + 1))
                fi
            fi
        done

        # /usr/local/bin contient à la fois des liens brew ET potentiellement
        # d'autres trucs. On chown UNIQUEMENT les symlinks créés par brew.
        if [ -d "$BREW_PREFIX/bin" ]; then
            log "Chown des symlinks brew dans $BREW_PREFIX/bin..."
            # Trouve les liens dans /usr/local/bin qui pointent vers /usr/local/Cellar ou /usr/local/opt
            find "$BREW_PREFIX/bin" -type l 2>/dev/null | while IFS= read -r link; do
                target=$(readlink "$link" 2>/dev/null || true)
                if echo "$target" | grep -qE "(Cellar|opt)/"; then
                    chown -h "${SERVICE_USER}:admin" "$link" 2>/dev/null || true
                fi
            done
            log "  ✓ Symlinks brew /usr/local/bin chownés"
        fi

        if [ "$failed" -gt 0 ]; then
            log "[WARN] $failed dossier(s) n'ont pas pu être chownés (cf. ci-dessus)"
            log "       brew peut quand même fonctionner si les dossiers principaux sont OK"
        fi
    else
        # Apple Silicon : on chown tout /opt/homebrew d'un coup
        log "Correction ownership (Apple Silicon : tout $BREW_PREFIX)"
        if chown -R "${SERVICE_USER}:admin" "$BREW_PREFIX"; then
            log "✓ Ownership corrigé"
        else
            log "[ERROR] Impossible de chown $BREW_PREFIX"
            return 1
        fi
    fi
    return 0
}

# -------------------------------------------------------------------------
# 2. Skip si déjà installé (mais corrige l'ownership si besoin)
# -------------------------------------------------------------------------
if [ -x "$BREW_BIN" ]; then
    BREW_VERSION=$("$BREW_BIN" --version 2>/dev/null | head -1 || echo "unknown")
    log "Homebrew déjà installé : $BREW_VERSION"

    # Vérifie l'ownership d'un sous-dossier représentatif (pas /usr/local lui-même)
    if [ "$IS_INTEL" = "1" ]; then
        OWNER_CHECK_DIR="$BREW_PREFIX/Homebrew"
    else
        OWNER_CHECK_DIR="$BREW_PREFIX"
    fi

    if [ -d "$OWNER_CHECK_DIR" ]; then
        BREW_OWNER=$(stat -f%Su "$OWNER_CHECK_DIR")
        log "  Propriétaire de $OWNER_CHECK_DIR : $BREW_OWNER"

        if [ "$BREW_OWNER" != "$SERVICE_USER" ]; then
            log "[WARN] Homebrew n'appartient pas à $SERVICE_USER"
            fix_brew_ownership || {
                log "[ERROR] La correction d'ownership a échoué"
                exit 1
            }
        else
            log "  ✓ Ownership OK"
        fi
    fi

    log "=== Homebrew install: nothing to do ==="
    exit 0
fi

# -------------------------------------------------------------------------
# 3. Vérifier que sp-installer existe
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
log "Téléchargement et installation de Homebrew (peut prendre 2-5 minutes)..."

SERVICE_HOME=$(dscl . -read "/Users/$SERVICE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -z "$SERVICE_HOME" ] && SERVICE_HOME="/var/$SERVICE_USER"

mkdir -p "$SERVICE_HOME"
chown "${SERVICE_USER}:admin" "$SERVICE_HOME"
chmod 750 "$SERVICE_HOME"

INSTALL_CMD="cd \"$SERVICE_HOME\" && NONINTERACTIVE=1 CI=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

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

# -------------------------------------------------------------------------
# 7. Vérifier que Cask est dispo (intégré nativement)
# -------------------------------------------------------------------------
if sudo -u "$SERVICE_USER" -H "$BREW_BIN" --help | grep -q -- '--cask'; then
    log "Cask : intégré ✓ (brew install --cask <name> fonctionnera)"
else
    log "[WARN] Cask ne semble pas disponible dans cette version de Homebrew"
fi

# -------------------------------------------------------------------------
# 8. Configurer le PATH pour TOUS les users (système-wide)
# -------------------------------------------------------------------------
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

add_to_system_rc "/etc/zshrc"
add_to_system_rc "/etc/bashrc"

# -------------------------------------------------------------------------
# 9. brew update initial
# -------------------------------------------------------------------------
log "Lancement de brew update..."
sudo -u "$SERVICE_USER" -H "$BREW_BIN" update >> "$LOG" 2>&1 || {
    log "[WARN] brew update a échoué (non-bloquant)"
}

log "=== Homebrew install successful ==="
log "Owner   : $SERVICE_USER"
log "Path    : $BREW_PREFIX"
log "Version : $BREW_VERSION"

exit 0