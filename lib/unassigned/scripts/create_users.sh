#!/bin/bash

# Mots de passe injectés par Fleet via secret variables
SHERIFF_PASS="$FLEET_SECRET_SHERIFF_PASSWORD"

if [ -z "$SHERIFF_PASS" ]; then
    echo "Erreur : mots de passe manquants dans Fleet Secrets."
    exit 1
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


pwpolicy -u sheriff -setpolicy "newPasswordRequired=1"

echo "Provisioning des comptes terminé."