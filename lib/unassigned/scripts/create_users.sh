#!/bin/bash
set -euo pipefail

# Mots de passe injectés par Fleet via secret variables
ADMIN_PASS="$FLEET_SECRET_ADMIN_PASSWORD"
SHERIFF_PASS="$FLEET_SECRET_SHERIFF_PASSWORD"

if [ -z "$ADMIN_PASS" ] || [ -z "$SHERIFF_PASS" ]; then
    echo "Erreur : mots de passe manquants dans Fleet Secrets."
    exit 1
fi

# --- Compte admin (caché, administrateur) ---
if ! id admin &>/dev/null; then
    sysadminctl -addUser admin \
        -fullName "Admin" \
        -password "$ADMIN_PASS" \
        -admin \
        -home /Users/admin \
        -shell /bin/zsh
    # Cacher le compte du login window et de Users & Groups
    dscl . create /Users/admin IsHidden 1
    # Cacher aussi le home directory du Finder
    chflags hidden /Users/admin
    echo "Compte admin créé."
else
    echo "Compte admin déjà présent, skip."
fi

# --- Compte sheriff (utilisateur standard) ---
if ! id sheriff &>/dev/null; then
    sysadminctl -addUser sheriff \
        -fullName "Sheriff Projects" \
        -password "$SHERIFF_PASS" \
        -home /Users/sheriff \
        -shell /bin/zsh
    echo "Compte sheriff créé."
else
    echo "Compte sheriff déjà présent, skip."
fi

# Forcer le changement de mot de passe sheriff au premier login (optionnel)
# pwpolicy -u sheriff -setpolicy "newPasswordRequired=1"

echo "Provisioning des comptes terminé."