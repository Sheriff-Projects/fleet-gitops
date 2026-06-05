#!/bin/bash
# create_service_admin.sh
#
# Crée un compte admin de service caché "sp-installer" qui sera utilisé par
# Fleet pour les installs nécessitant sudo (Homebrew, Cask, etc.).
#
# Le compte :
#   - UID 499 (caché du login window, qui n'affiche que UID >= 500)
#   - Membre du groupe admin (peut faire sudo)
#   - Pas de shell de login (UserShell=/usr/bin/false)
#   - Pas de password utilisable (compte verrouillé)
#   - sudoers NOPASSWD permanent (pour que Fleet/root puisse faire
#     `sudo -u sp-installer ...` sans prompt)
#
# Conséquence : les utilisateurs finaux (samir.ouari, etc.) restent STANDARD.
# Seul ce compte caché a admin, et personne ne peut s'y logger.
#
# Logs : /var/log/sp_installer_setup.log

set -uo pipefail

# ===========================================================================
# CONFIG
# ===========================================================================
SERVICE_USER="sp-installer"
SERVICE_UID="499"           # < 500 = hidden from login window
SERVICE_HOME="/var/${SERVICE_USER}"
SERVICE_REALNAME="Sheriff Projects Service Installer"

SUDOERS_FILE="/etc/sudoers.d/sheriffprojects-${SERVICE_USER}"
LOG="/var/log/sp_installer_setup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Setup sp-installer service admin started ==="

# -------------------------------------------------------------------------
# 1. Vérifier si le compte existe déjà (idempotence)
# -------------------------------------------------------------------------
if id "$SERVICE_USER" >/dev/null 2>&1; then
    log "$SERVICE_USER existe déjà"

    # Vérifie qu'il est bien dans admin
    if dseditgroup -o checkmember -m "$SERVICE_USER" admin >/dev/null 2>&1; then
        log "✓ Déjà membre du groupe admin"
    else
        log "Pas dans admin, ajout..."
        dseditgroup -o edit -a "$SERVICE_USER" -t user admin || {
            log "[ERROR] dseditgroup a échoué"
            exit 1
        }
    fi
else
    log "Création du compte $SERVICE_USER (UID $SERVICE_UID)..."

    # -------------------------------------------------------------------------
    # 2. Créer l'utilisateur via dscl
    # -------------------------------------------------------------------------
    dscl . -create "/Users/$SERVICE_USER"
    dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
    dscl . -create "/Users/$SERVICE_USER" RealName "$SERVICE_REALNAME"
    dscl . -create "/Users/$SERVICE_USER" UniqueID "$SERVICE_UID"
    dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID 80  # admin group
    dscl . -create "/Users/$SERVICE_USER" NFSHomeDirectory "$SERVICE_HOME"

    # Pas de password utilisable (compte verrouillé)
    # On utilise un hash bidon qui ne correspondra jamais à un password
    dscl . -create "/Users/$SERVICE_USER" Password "*"

    # Cache le compte du login window (extra protection même si UID < 500 suffit)
    dscl . -create "/Users/$SERVICE_USER" IsHidden 1

    # Créer le dossier home
    mkdir -p "$SERVICE_HOME"
    chown "${SERVICE_USER}:admin" "$SERVICE_HOME"
    chmod 750 "$SERVICE_HOME"

    # Ajouter au groupe admin
    dseditgroup -o edit -a "$SERVICE_USER" -t user admin

    log "✓ Compte $SERVICE_USER créé (UID $SERVICE_UID, admin, hidden)"
fi

# -------------------------------------------------------------------------
# 3. Configurer sudoers NOPASSWD pour sp-installer (permanent)
# -------------------------------------------------------------------------
if [ -f "$SUDOERS_FILE" ]; then
    log "Sudoers file existe déjà : $SUDOERS_FILE"
else
    log "Création de $SUDOERS_FILE..."

    cat > "$SUDOERS_FILE" << EOF
# Sheriff Projects service admin
# Allows sp-installer to run sudo commands without password.
# Used by Fleet MDM for Homebrew/Cask/other software installs.
${SERVICE_USER} ALL=(ALL) NOPASSWD: ALL
EOF

    chmod 0440 "$SUDOERS_FILE"
    chown root:wheel "$SUDOERS_FILE"

    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        log "✓ Sudoers configuré pour $SERVICE_USER"
    else
        log "[ERROR] Sudoers syntax invalide, on supprime"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
fi

# -------------------------------------------------------------------------
# 4. Vérifications finales
# -------------------------------------------------------------------------
log "Vérifications finales :"

# UID
ACTUAL_UID=$(id -u "$SERVICE_USER" 2>/dev/null)
log "  UID         : $ACTUAL_UID"

# Groupes
GROUPS_LIST=$(id -Gn "$SERVICE_USER" 2>/dev/null)
log "  Groupes     : $GROUPS_LIST"

# Membre admin ?
if echo "$GROUPS_LIST" | grep -qw admin; then
    log "  Admin       : ✓"
else
    log "  Admin       : ✗ (PROBLÈME)"
    exit 1
fi

# Home directory
if [ -d "$SERVICE_HOME" ]; then
    log "  Home dir    : ✓ $SERVICE_HOME"
fi

# Shell verrouillé
ACTUAL_SHELL=$(dscl . -read "/Users/$SERVICE_USER" UserShell 2>/dev/null | awk '{print $2}')
log "  Shell       : $ACTUAL_SHELL"

# Hidden ?
IS_HIDDEN=$(dscl . -read "/Users/$SERVICE_USER" IsHidden 2>/dev/null | awk '{print $2}')
log "  IsHidden    : $IS_HIDDEN"

# Test sudo NOPASSWD
if sudo -n -u "$SERVICE_USER" /usr/bin/true >/dev/null 2>&1; then
    log "  Sudo test   : ✓ root peut su vers $SERVICE_USER sans password"
else
    log "  Sudo test   : ✗ (PROBLÈME — vérifier $SUDOERS_FILE)"
fi

log "=== Setup sp-installer successful ==="
exit 0