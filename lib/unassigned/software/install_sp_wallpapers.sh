#!/bin/bash
#
# Install script — S•P Wallpapers
# Le PKG contient les fichiers ; ce script ajoute le dossier comme source
# de fonds d'écran dans les Préférences Système.
#
# Tourne en root via Fleet. $INSTALLER_PATH = chemin du .pkg fourni par Fleet.
#

set -uo pipefail

LOG="/var/log/sp_wallpapers_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== S•P Wallpapers install démarré ==="

# --- 1. Installer le PKG ---
if [ -n "${INSTALLER_PATH:-}" ] && [ -f "$INSTALLER_PATH" ]; then
    log "Installation du PKG : $INSTALLER_PATH"
    if /usr/sbin/installer -pkg "$INSTALLER_PATH" -target / >>"$LOG" 2>&1; then
        log "PKG installé avec succès"
    else
        log "ERREUR : installation du PKG échouée"
        exit 1
    fi
else
    log "ATTENTION : INSTALLER_PATH non défini ou introuvable"
fi

# --- 2. Détecter l'utilisateur connecté à la console ---
username=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || echo "")

if [ -z "$username" ] || [ "$username" = "root" ] || [ "$username" = "loginwindow" ]; then
    log "Aucun utilisateur connecté à la console — config user-level différée"
    USER_CONFIG=false
else
    log "Utilisateur console détecté : $username"
    USER_CONFIG=true
fi

# --- 3. Préférences NIVEAU SYSTÈME (toujours appliquées) ---
log "Configuration des préférences système..."
/usr/bin/defaults write /Library/Preferences/com.apple.systempreferences \
    DSKDesktopPrefPane \
    '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>' \
    || log "ATTENTION : écriture du plist système échouée"

# --- 4. Préférences NIVEAU UTILISATEUR (si user connecté) ---
if [ "$USER_CONFIG" = true ]; then
    user_uid=$(/usr/bin/id -u "$username" 2>/dev/null || echo "")
    user_plist="/Users/$username/Library/Preferences/com.apple.systempreferences.plist"

    # Supprimer l'ancien plist s'il existe (pour forcer la régénération)
    if [ -f "$user_plist" ]; then
        log "Suppression de l'ancien plist : $user_plist"
        /bin/rm -f "$user_plist"
    fi

    # Écrire le nouveau plist DANS LE CONTEXTE de l'utilisateur (pas en root)
    log "Écriture des préférences pour $username..."
    /usr/bin/sudo -u "$username" /usr/bin/defaults write \
        com.apple.systempreferences \
        DSKDesktopPrefPane \
        '<dict><key>UserFolderPaths</key><array><string>/Users/Shared/sp_wallpapers</string></array></dict>' \
        || log "ATTENTION : écriture du plist user échouée"

    # Recharger cfprefsd côté utilisateur (sans erreur si déjà mort)
    if [ -n "$user_uid" ]; then
        /bin/launchctl asuser "$user_uid" /usr/bin/killall -HUP cfprefsd 2>/dev/null || true
    fi
fi

# --- 5. Recharger cfprefsd système ---
/usr/bin/killall -HUP cfprefsd 2>/dev/null || true

# --- 6. Fermer System Settings si ouvert (optionnel — toujours exit 0) ---
/usr/bin/killall "System Settings" 2>/dev/null || true
/usr/bin/killall "System Preferences" 2>/dev/null || true

log "=== S•P Wallpapers install terminé ==="
exit 0