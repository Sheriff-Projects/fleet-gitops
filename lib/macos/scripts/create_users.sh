#!/bin/bash
# ============================================================================
#  Comptes locaux Sheriff : "admin" (administrateur) + "sheriff" (standard)
#  Exécuté en root par Fleet (policy auto-réparatrice).
#
#  Mots de passe injectés par Fleet via SECRET VARIABLES — jamais en clair ici.
#  Définir dans les secrets GitHub / Fleet :
#     FLEET_SECRET_ADMIN_PASSWORD    (mot de passe du compte admin)
#     FLEET_SECRET_SHERIFF_PASSWORD  (mot de passe du compte sheriff, ex. rodeokid)
#
#  NB : FileVault est désactivé sur le parc → le Secure Token n'est PAS requis
#       pour que ces comptes soient pleinement fonctionnels (login, sudo, GUI).
#       On contourne ainsi le blocage Secure/Bootstrap Token d'Apple Silicon.
#
#  Idempotent : ne recrée pas un compte déjà présent.
#  Logs : /var/log/sheriff_create_users.log
# ============================================================================
set -uo pipefail

ADMIN_USER="admin"
ADMIN_REALNAME="Administrateur Sheriff"
ADMIN_PASS="$FLEET_SECRET_ADMIN_PASSWORD"

STD_USER="sheriff"
STD_REALNAME="Sheriff"
STD_PASS="$FLEET_SECRET_SHERIFF_PASSWORD"

LOG="/var/log/sheriff_create_users.log"
log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG"; }

log "=== create_users.sh démarré ==="

if [ -z "${ADMIN_PASS}" ] || [ -z "${STD_PASS}" ]; then
  log "[ERREUR] Secret(s) manquant(s) : FLEET_SECRET_ADMIN_PASSWORD / FLEET_SECRET_SHERIFF_PASSWORD."
  exit 1
fi

# --- Compte admin (administrateur) ------------------------------------------
if id "$ADMIN_USER" >/dev/null 2>&1; then
  log "Compte '$ADMIN_USER' déjà présent — skip."
else
  log "Création de '$ADMIN_USER' (administrateur)..."
  if sysadminctl -addUser "$ADMIN_USER" -fullName "$ADMIN_REALNAME" -password "$ADMIN_PASS" -admin >>"$LOG" 2>&1; then
    log "✓ '$ADMIN_USER' créé (admin)."
  else
    log "[ERREUR] Création de '$ADMIN_USER' échouée."
    exit 1
  fi
fi

# --- Compte utilisateur standard (sheriff) ----------------------------------
if id "$STD_USER" >/dev/null 2>&1; then
  log "Compte '$STD_USER' déjà présent — skip."
else
  log "Création de '$STD_USER' (utilisateur standard)..."
  if sysadminctl -addUser "$STD_USER" -fullName "$STD_REALNAME" -password "$STD_PASS" >>"$LOG" 2>&1; then
    log "✓ '$STD_USER' créé (standard)."
  else
    log "[ERREUR] Création de '$STD_USER' échouée."
    exit 1
  fi
fi

# --- Garantir que 'sheriff' reste STANDARD (jamais admin) -------------------
if id -Gn "$STD_USER" 2>/dev/null | grep -qw admin; then
  log "'$STD_USER' est dans le groupe admin → rétrogradation en standard."
  dseditgroup -o edit -d "$STD_USER" -t user admin >>"$LOG" 2>&1 \
    || log "[WARN] Retrait de '$STD_USER' du groupe admin échoué."
fi

log "=== create_users.sh terminé OK ==="
exit 0
