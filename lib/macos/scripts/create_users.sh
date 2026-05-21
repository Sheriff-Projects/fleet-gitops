@ -1,32 +1,13 @@
#!/bin/bash
set -euo pipefail

# Mots de passe injectés par Fleet via secret variables
SHERIFF_PASS="$FLEET_SECRET_SHERIFF_PASSWORD"

if [ -z "$SHERIFF_PASS" ]; then
    echo "Erreur : mot de passe manquant dans Fleet Secrets."
    exit 1
fi


# --- Compte sheriff (utilisateur standard) ---
if ! id sheriff &>/dev/null; then
    sysadminctl -addUser sheriff \
@ -39,7 +20,7 @@ else
    echo "Compte sheriff déjà présent, skip."
fi

# Forcer le changement de mot de passe sheriff au premier login (optionnel)
# pwpolicy -u sheriff -setpolicy "newPasswordRequired=1"


echo "Provisioning des comptes terminé."