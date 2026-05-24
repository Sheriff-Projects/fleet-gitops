#!/bin/bash
# Build le PKG FortiClient VPN Config.
# Ce PKG est INDÉPENDANT du PKG FortiClient principal. Il pose le vpn.plist
# partagé à /Library/Application Support/Fortinet/FortiClient/conf/vpn.plist
# et redémarre les agents FortiClient pour qu'ils relisent la config.
#
# À déployer APRÈS FortiClient dans Fleet (pour que les chemins existent et que
# les agents soient en place).
#
# Sources :
#   lib/macos/configuration-apps/vpn.plist  → fichier de config versionné dans Git
#
# Produits :
#   lib/macos/download/forticlient_vpn_config.pkg
#   lib/macos/software/forticlient_vpn_config.yml
#   lib/macos/software/install_forticlient_vpn_config.sh
#   lib/macos/software/uninstall_forticlient_vpn_config.sh

set -euo pipefail

# --- Couleurs (auto-désactivées en CI sans tty) ---
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
else
    GREEN=''; BLUE=''; YELLOW=''; RED=''; NC=''
fi

# --- Détection du répertoire du repo ---
if [ -n "${FLEET_GITOPS_REPO_PATH:-}" ]; then
    REPO_ROOT="$FLEET_GITOPS_REPO_PATH"
else
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
fi

if [ ! -d "$REPO_ROOT/lib/macos" ]; then
    echo -e "${RED}[ERROR] Le répertoire $REPO_ROOT/lib/macos n'existe pas.${NC}"
    echo "Définis FLEET_GITOPS_REPO_PATH ou place ce script dans <repo>/scripts/"
    exit 1
fi

# --- Configuration ---
VPN_PLIST_SOURCE="$REPO_ROOT/lib/macos/configuration-apps/vpn.plist"
VPN_PLIST_TARGET_RELATIVE="Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

DOWNLOAD_DIR="$REPO_ROOT/lib/macos/download"
OUTPUT_PKG="$DOWNLOAD_DIR/forticlient_vpn_config.pkg"
SOFTWARE_DIR="$REPO_ROOT/lib/macos/software"
YAML_FILE="$SOFTWARE_DIR/forticlient_vpn_config.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_forticlient_vpn_config.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_forticlient_vpn_config.sh"

REPO="Sheriff-Projects/fleet-gitops"
PKG_URL="https://github.com/${REPO}/releases/download/forticlient_vpn_config/forticlient_vpn_config.pkg"

# Identifiant unique pour ce PKG (pas le même que com.fortinet.FortiClient pour
# que les deux PKG puissent cohabiter dans pkgutil)
PKG_IDENTIFIER="com.sheriffprojects.forticlient.vpnconfig"

# Version basée sur la date du build — change automatiquement à chaque rebuild,
# ce qui force Fleet à re-déployer si on relance le builder.
PKG_VERSION="$(date '+%Y.%m.%d.%H%M%S')"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
PAYLOAD_ROOT="$BUILD_DIR/payload-root"

trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   FortiClient VPN Config — PKG Builder   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"
echo ""

# --- Étape 1 : Validation du vpn.plist source ---
echo -e "${BLUE}[1/5] Validating vpn.plist source...${NC}"

if [ ! -f "$VPN_PLIST_SOURCE" ]; then
    echo -e "${RED}[ERROR] $VPN_PLIST_SOURCE introuvable${NC}"
    echo -e "${YELLOW}Crée ce fichier avant de relancer le builder :${NC}"
    echo "  mkdir -p $REPO_ROOT/lib/macos/configuration-apps"
    echo "  cp /chemin/vers/ton/vpn.plist $VPN_PLIST_SOURCE"
    exit 1
fi

if ! plutil -lint "$VPN_PLIST_SOURCE" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] $VPN_PLIST_SOURCE n'est pas un plist XML valide${NC}"
    plutil -lint "$VPN_PLIST_SOURCE"
    exit 1
fi

VPN_SRC_SIZE=$(wc -c < "$VPN_PLIST_SOURCE" | tr -d ' ')
VPN_SRC_SHA=$(shasum -a 256 "$VPN_PLIST_SOURCE" | awk '{print $1}')
echo -e "${GREEN}  ✓ Source: $VPN_PLIST_SOURCE${NC}"
echo -e "${GREEN}  ✓ Size:   $VPN_SRC_SIZE bytes${NC}"
echo -e "${GREEN}  ✓ SHA256: ${VPN_SRC_SHA:0:16}...${NC}"
echo ""

# --- Étape 2 : Construction du payload root ---
# On reproduit l'arborescence exacte du chemin cible. installer(8) déballera
# ce payload à / avec ownership root:wheel et les permissions du fichier source.
echo -e "${BLUE}[2/5] Building PKG payload structure...${NC}"

VPN_TARGET_DIR="$PAYLOAD_ROOT/$(dirname "$VPN_PLIST_TARGET_RELATIVE")"
mkdir -p "$VPN_TARGET_DIR"
cp "$VPN_PLIST_SOURCE" "$VPN_TARGET_DIR/vpn.plist"
chmod 0644 "$VPN_TARGET_DIR/vpn.plist"

echo -e "${GREEN}  ✓ Payload structure:${NC}"
find "$PAYLOAD_ROOT" -type f -o -type d | sed "s|$PAYLOAD_ROOT|    |"
echo ""

# --- Étape 3 : Génération du postinstall (kill + restart agents) ---
# Le postinstall est exécuté par installer(8) APRÈS que le vpn.plist a été posé.
# Il tue les agents FortiClient (qui peuvent avoir une ancienne config en mémoire)
# puis les redémarre dans la bonne session pour qu'ils relisent le fichier.
echo -e "${BLUE}[3/5] Generating postinstall (kill + restart agents)...${NC}"

mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << 'EOF'
#!/bin/bash
# Postinstall du PKG forticlient_vpn_config.pkg
# Le vpn.plist vient d'être posé par installer(8). On redémarre les agents
# FortiClient pour qu'ils relisent la nouvelle config.

LOG="/var/log/forticlient_vpn_config_install.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

log "=== VPN config postinstall started ==="

VPN_CONF_PATH="/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"
if [ -f "$VPN_CONF_PATH" ]; then
    VPN_SIZE=$(stat -f%z "$VPN_CONF_PATH" 2>/dev/null || echo "?")
    log "vpn.plist posed at $VPN_CONF_PATH (${VPN_SIZE} bytes)"
else
    log "[WARN] vpn.plist not at expected path — installer(8) may have failed"
fi

# Vérifie que FortiClient est installé (sinon ce PKG n'a rien à reload)
if [ ! -d "/Applications/FortiClient.app" ]; then
    log "[WARN] FortiClient.app not installed — VPN config posed but no agents to reload"
    log "=== VPN config postinstall done (FortiClient absent) ==="
    exit 0
fi

# Stoppe les agents userspace (ils tiennent l'ancienne config en mémoire)
log "Stopping Fortinet agents to force config reload..."
pkill -9 -i -f "FortiTray|FortiClientAgent|FctMiscAgent|CredentialStore|FortiClient\.app/Contents/MacOS/FortiClient" 2>/dev/null || true
sleep 2

# Redémarrer les LaunchDaemons (system domain — root)
log "Restarting Fortinet LaunchDaemons (system domain)..."
for daemon in /Library/LaunchDaemons/com.fortinet.*.plist; do
    [ -e "$daemon" ] || continue
    log "  bootout + bootstrap $daemon"
    launchctl bootout system "$daemon" 2>/dev/null || true
    launchctl bootstrap system "$daemon" 2>/dev/null \
        || launchctl load "$daemon" 2>/dev/null \
        || true
done

# Redémarrer les LaunchAgents dans la session GUI utilisateur
log "Restarting Fortinet LaunchAgents (user GUI session)..."
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "")

if [ -n "$CONSOLE_UID" ] && [ "$CONSOLE_UID" != "0" ]; then
    log "  Target user: $CONSOLE_USER (uid=$CONSOLE_UID)"
    for agent in /Library/LaunchAgents/com.fortinet.*.plist; do
        [ -e "$agent" ] || continue
        log "  bootout + bootstrap $agent"
        launchctl bootout "gui/$CONSOLE_UID" "$agent" 2>/dev/null || true
        launchctl bootstrap "gui/$CONSOLE_UID" "$agent" 2>/dev/null \
            || launchctl asuser "$CONSOLE_UID" launchctl load "$agent" 2>/dev/null \
            || true
    done
else
    log "  [WARN] No user logged in GUI — agents will load with new config at next login"
fi

log "=== VPN config postinstall successful ==="
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ Postinstall script created${NC}"
echo ""

# --- Étape 4 : Build du PKG ---
echo -e "${BLUE}[4/5] Building PKG...${NC}"

mkdir -p "$DOWNLOAD_DIR"
rm -f "$OUTPUT_PKG"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$PKG_VERSION" \
    --root "$PAYLOAD_ROOT" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>FortiClient VPN Config (Sheriff Projects)</title>
    <pkg-ref id="$PKG_IDENTIFIER"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_IDENTIFIER" visible="false">
        <pkg-ref id="$PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$PKG_IDENTIFIER" version="$PKG_VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution "$DIST_XML" \
    --package-path "$BUILD_DIR" \
    "$OUTPUT_PKG" > /dev/null

if [ ! -f "$OUTPUT_PKG" ]; then
    echo -e "${RED}[ERROR] PKG build failed${NC}"
    exit 1
fi

PKG_SIZE=$(du -h "$OUTPUT_PKG" | awk '{print $1}')
PKG_HASH=$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')

if [ -z "$PKG_HASH" ] || [ ${#PKG_HASH} -ne 64 ]; then
    echo -e "${RED}[ERROR] Invalid SHA-256 computed${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ PKG built: $OUTPUT_PKG ($PKG_SIZE)${NC}"
echo -e "${GREEN}  ✓ Version:   $PKG_VERSION${NC}"
echo -e "${GREEN}  ✓ SHA256:    $PKG_HASH${NC}"
echo ""

# --- Étape 5 : Génération des scripts Fleet (install + uninstall) ---
echo -e "${BLUE}[5/5] Generating Fleet install/uninstall scripts + YAML...${NC}"

mkdir -p "$SOFTWARE_DIR"

# Le install_script Fleet est minimal : il télécharge le PKG (qui est tout petit)
# et le passe à installer(8). Toute la logique (kill+restart agents) est dans
# le postinstall du PKG lui-même → atomique et auto-suffisant.
cat > "$INSTALL_SCRIPT" << EOF
#!/bin/bash
# Install script FortiClient VPN config — wrapper minimal autour de installer(8).
# Le PKG contient le vpn.plist dans son payload et un postinstall qui redémarre
# les agents FortiClient. Pas de logique métier ici.
#
# Built on $(date '+%Y-%m-%d %H:%M:%S')
# PKG version: $PKG_VERSION

set -uo pipefail

PKG_URL="$PKG_URL"
TEMP_DIR=\$(mktemp -d)
PKG_PATH="\$TEMP_DIR/forticlient_vpn_config.pkg"
LOG="/var/log/forticlient_vpn_config_install.log"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$LOG"; }
cleanup() { rm -rf "\$TEMP_DIR"; }
trap cleanup EXIT

log "=== FortiClient VPN config install started ==="

# Vérification préalable : FortiClient doit être installé pour que ça serve
if [ ! -d "/Applications/FortiClient.app" ]; then
    log "[WARN] FortiClient.app non installé — installe FortiClient d'abord, puis cette config."
    log "       La config sera posée quand même, elle sera utilisée au prochain démarrage de FortiClient."
fi

# Téléchargement du PKG (petit, < 10 Ko)
log "Downloading PKG from \$PKG_URL..."
if ! curl -sSL --fail --max-time 60 "\$PKG_URL" -o "\$PKG_PATH"; then
    log "[ERROR] Download failed"
    exit 1
fi

PKG_DL_SIZE=\$(du -h "\$PKG_PATH" | awk '{print \$1}')
log "Downloaded: \$PKG_DL_SIZE"

# Installation (le postinstall du PKG fait le restart des agents)
log "Running installer -pkg..."
if ! installer -pkg "\$PKG_PATH" -target / >> "\$LOG" 2>&1; then
    log "[ERROR] installer command failed"
    exit 1
fi

log "=== FortiClient VPN config install successful ==="
exit 0
EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ Generated: $INSTALL_SCRIPT${NC}"

cat > "$YAML_FILE" << EOF
- url: $PKG_URL
  hash_sha256: $PKG_HASH
  install_script:
    path: ./install_forticlient_vpn_config.sh
  uninstall_script:
    path: ./uninstall_forticlient_vpn_config.sh
EOF

echo -e "${GREEN}  ✓ Generated: $YAML_FILE${NC}"
echo ""

# --- Sortie compatible GitHub Actions ---
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$PKG_VERSION"
        echo "pkg_path=$OUTPUT_PKG"
        echo "pkg_hash=$PKG_HASH"
        echo "pkg_size=$PKG_SIZE"
        echo "vpn_source_size=$VPN_SRC_SIZE"
        echo "vpn_source_sha=$VPN_SRC_SHA"
    } >> "$GITHUB_OUTPUT"
fi

# ===========================================================================
# *** AJOUT : Upload du .pkg dans GitHub Release (approche directe) ***
# ===========================================================================
# Au lieu de committer le .pkg dans Git (qui forçait Fleet GitOps à le
# télécharger via raw.githubusercontent.com avec un timing fragile), on
# uploade directement le .pkg dans une GitHub Release dédiée. Le YAML que
# l'on commit en fin de script pointe déjà vers cette release, donc Fleet
# GitOps n'aura aucun problème de race condition pour trouver le .pkg.
#
# Prérequis : gh CLI installé et authentifié (gh auth login).
# ===========================================================================
RELEASE_TAG=$(basename "$OUTPUT_PKG" .pkg)
PKG_FILENAME=$(basename "$OUTPUT_PKG")

# Crée la release si elle n'existe pas
if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo -e "${BLUE}[*] Création de la release ${RELEASE_TAG}...${NC}"
    gh release create "$RELEASE_TAG" \
        --repo "$REPO" \
        --title "$RELEASE_TAG" \
        --notes "Package $PKG_FILENAME for Fleet GitOps"
    echo -e "${GREEN}  ✓ Release créée${NC}"
fi

# Upload le .pkg (--clobber écrase si l'asset existe déjà)
echo -e "${BLUE}[*] Upload du .pkg dans la release ${RELEASE_TAG}...${NC}"
gh release upload "$RELEASE_TAG" "$OUTPUT_PKG" --clobber --repo "$REPO"
echo -e "${GREEN}  ✓ .pkg uploadé : https://github.com/${REPO}/releases/tag/${RELEASE_TAG}${NC}"

# Supprime le .pkg local (il vit maintenant dans la release)
rm -f "$OUTPUT_PKG"
echo -e "${GREEN}  ✓ .pkg local supprimé${NC}"
echo ""

# ===========================================================================
# *** MODIFIÉ : Commit + push du YAML seulement (pas le .pkg) ***
# ===========================================================================
# Le .pkg vit maintenant dans une GitHub Release (uploadé juste avant via gh).
# On ne commit QUE le YAML (qui contient l'URL release + le hash mis à jour).
# Pas de race condition possible avec Fleet GitOps puisque la release existe
# DÉJÀ au moment où l'on push le YAML.
# ===========================================================================
echo -e "${BLUE}[*] Commit + push du YAML...${NC}"

cd "$REPO_ROOT"
git add "$YAML_FILE"

if git diff --staged --quiet; then
    echo -e "${YELLOW}  ⚠ Aucun changement à committer${NC}"
else
    COMMIT_MSG="package release: $RELEASE_TAG $PKG_VERSION"
    git commit -m "$COMMIT_MSG"
    git push
    echo -e "${GREEN}  ✓ Pushed: $COMMIT_MSG${NC}"
fi
echo ""
# --- Récap ---
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Build terminé${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo "  vpn.plist source : $VPN_PLIST_SOURCE"
echo "  vpn.plist size   : $VPN_SRC_SIZE bytes"
echo "  PKG version      : $PKG_VERSION"
echo "  PKG identifier   : $PKG_IDENTIFIER"
echo "  PKG path         : $OUTPUT_PKG"
echo "  PKG size         : $PKG_SIZE"
echo "  SHA256           : $PKG_HASH"
echo "  Install script   : $INSTALL_SCRIPT"
echo "  Uninstall script : $UNINSTALL_SCRIPT"
echo "  YAML             : $YAML_FILE"
echo ""
echo "  Cible sur Mac    : /$VPN_PLIST_TARGET_RELATIVE"
echo "  Permissions      : root:wheel 0644 (posées par installer(8))"
echo "  Postinstall      : kill + bootstrap des agents Fortinet"
echo ""
echo "  À déployer APRÈS FortiClient dans Fleet :"
echo "    packages:"
echo "      - path: ../lib/macos/software/forticlient.yml"
echo "        self_service: true"
echo "      - path: ../lib/macos/software/forticlient_vpn_config.yml"
echo "        self_service: true"
echo " "