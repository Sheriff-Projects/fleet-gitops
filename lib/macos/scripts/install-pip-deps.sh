#!/bin/bash
# install_ccdl_python_deps.sh
#
# Installe les dépendances Python requises par ccdl.py.
# À déployer APRÈS ccdl.pkg et APRÈS Xcode Command Line Tools.
#
# ccdl.py importe :
#   - requests (HTTP library, pas dans la stdlib)
#   - et potentiellement d'autres modules selon la version
#
# Méthode :
#   1. Détecte le python3 fonctionnel (CLT ou Python.org)
#   2. Installe pip3 si absent
#   3. Installe les modules via pip3
#
# Logs : /var/log/ccdl_python_deps.log

set -uo pipefail

LOG="/var/log/ccdl_python_deps.log"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== ccdl Python deps install started ==="

# -------------------------------------------------------------------------
# 1. Vérifier que python3 fonctionne
# -------------------------------------------------------------------------
if ! /usr/bin/python3 -c "import sys" >/dev/null 2>&1; then
    log "[ERROR] python3 ne fonctionne pas — déploie d'abord Xcode CLT"
    exit 1
fi

PY_VERSION=$(/usr/bin/python3 --version 2>&1)
log "python3 OK : $PY_VERSION"

# -------------------------------------------------------------------------
# 2. Liste des modules à installer
# -------------------------------------------------------------------------
# requests = utilisé par ccdl.py pour les requêtes HTTP vers les serveurs Adobe
# urllib3 = dépendance de requests
# certifi = certificats SSL (généralement déjà inclus mais on s'assure)
MODULES=("requests" "urllib3" "certifi")

# -------------------------------------------------------------------------
# 3. Vérifier si les modules sont déjà là (idempotence)
# -------------------------------------------------------------------------
ALL_PRESENT=1
for mod in "${MODULES[@]}"; do
    if /usr/bin/python3 -c "import $mod" >/dev/null 2>&1; then
        log "Module déjà installé : $mod"
    else
        log "Module manquant : $mod"
        ALL_PRESENT=0
    fi
done

if [ "$ALL_PRESENT" -eq 1 ]; then
    log "Tous les modules sont déjà présents"
    log "=== ccdl Python deps install: nothing to do ==="
    exit 0
fi

# -------------------------------------------------------------------------
# 4. Installer les modules via pip3
# -------------------------------------------------------------------------
# CLT fournit pip3 via /usr/bin/python3 -m pip
# Note : on installe en SYSTEM (sans --user) car ccdl.py tourne en root
log "Installation des modules manquants via pip..."

# --break-system-packages requis sur Python 3.11+ (PEP 668) pour install system-wide
# Sur Python plus ancien, l'option est ignorée (avec un warning OK)
PIP_ARGS="--break-system-packages"

# Tester si --break-system-packages est supporté ; sinon retirer
if ! /usr/bin/python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
    PIP_ARGS=""
    log "pip n'a pas --break-system-packages (Python ancien), install sans flag"
fi

for mod in "${MODULES[@]}"; do
    log "Installation : $mod"
    if /usr/bin/python3 -m pip install $PIP_ARGS --upgrade "$mod" >>"$LOG" 2>&1; then
        log "  ✓ $mod installé"
    else
        log "[ERROR] Échec install de $mod"
        exit 1
    fi
done

# -------------------------------------------------------------------------
# 5. Vérification finale
# -------------------------------------------------------------------------
log "Vérification finale..."
for mod in "${MODULES[@]}"; do
    if /usr/bin/python3 -c "import $mod; print('$mod', $mod.__version__)" 2>&1 | tee -a "$LOG"; then
        :
    else
        log "[ERROR] $mod ne s'importe toujours pas après install"
        exit 1
    fi
done

log "=== ccdl Python deps install successful ==="
exit 0