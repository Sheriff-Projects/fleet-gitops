#!/bin/bash
# ============================================================================
# Carbon Copy Cloner — PKG Builder  (généré par Fleet Package Factory)
# Type d'install : zip_app | Mode : fleet_install_script
# ============================================================================
# Ce script : détecte la dernière version, construit le .pkg, calcule le
# SHA256, met à jour le YAML Fleet, publie le .pkg en GitHub Release, puis
# commit/push uniquement le YAML (anti race-condition).
set -euo pipefail

# --- Couleurs (auto-désactivées en CI sans tty) ---
if [ -t 1 ]; then
    GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; BLUE=''; YELLOW=''; RED=''; NC=''
fi

# --- Détection du répertoire du repo ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -n "${FLEET_GITOPS_REPO_PATH:-}" ]; then
    REPO_ROOT="$FLEET_GITOPS_REPO_PATH"
else
    REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
fi
if [ ! -d "$REPO_ROOT/lib/macos" ]; then
    echo -e "${RED}[ERROR] $REPO_ROOT/lib/macos introuvable. Définis FLEET_GITOPS_REPO_PATH.${NC}"; exit 1
fi

# --- Configuration (issue de la fiche carbon_copy_cloner.yml) ---
REPO="Sheriff-Projects/fleet-gitops"
SLUG="carbon_copy_cloner"
RELEASE_TAG="carbon_copy_cloner"
DOWNLOAD_DIR="$REPO_ROOT/lib/macos/download"
OUTPUT_PKG="$DOWNLOAD_DIR/carbon_copy_cloner.pkg"
SOFTWARE_DIR="$REPO_ROOT/lib/macos/software"
YAML_FILE="$REPO_ROOT/lib/macos/software/carbon_copy_cloner.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_carbon_copy_cloner.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_carbon_copy_cloner.sh"
PKG_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${SLUG}.pkg"
PKG_IDENTIFIER="com.bombich.ccc"
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"
APP_PATH="/Applications/Carbon Copy Cloner.app"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
printf  "${BLUE}║ %-44s ║${NC}\n" "Carbon Copy Cloner — PKG Builder"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"; echo ""

# ============================================================================
# Détection de la dernière version — stratégie : filename_redirect
# ============================================================================
echo -e "${BLUE}[*] Détection de la dernière version...${NC}"


DOWNLOAD_URL_SRC="https://api.bombich.com/download/ccc?v=ccc7"
EFFECTIVE_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "$DOWNLOAD_URL_SRC" || echo "")
if [ -z "$EFFECTIVE_URL" ] || [ "$EFFECTIVE_URL" = "$DOWNLOAD_URL_SRC" ]; then echo -e "${RED}[ERROR] Pas de redirection détectée${NC}"; exit 1; fi
DOWNLOAD_URL="$EFFECTIVE_URL"
ARTIFACT_FILENAME=$(echo "$EFFECTIVE_URL" | sed 's#.*/##' | sed 's#?.*##')
RAW_VERSION=$(echo "$ARTIFACT_FILENAME" | sed -nE 's/^ccc-([0-9.]+)\.zip$/\1/p')


if [ -z "${RAW_VERSION:-}" ] || [ "$RAW_VERSION" = "null" ]; then echo -e "${RED}[ERROR] Version introuvable${NC}"; exit 1; fi

# Tronque à 3 segments (matche CFBundleShortVersionString de l'app installée)
LATEST_VERSION=$(echo "$RAW_VERSION" | awk -F. '{print $1"."$2"."$3}')


echo -e "${GREEN}  ✓ Version : $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ URL     : $DOWNLOAD_URL${NC}"
echo -e "${GREEN}  ✓ Bundle  : $PKG_IDENTIFIER${NC}"
echo ""

# ============================================================================
# Génération du postinstall embarqué dans le PKG
# Règle d'échappement heredoc : $VAR = build-time (valeur figée) ; \$VAR = runtime (Mac client)
# ============================================================================
mkdir -p "$SCRIPTS_DIR"


# --- PKG stub : postinstall no-op (vraie install dans install_carbon_copy_cloner.sh) ---
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Carbon Copy Cloner stub PKG installé (no-op)" >> /var/log/carbon_copy_cloner_install.log
exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"
echo -e "${GREEN}  ✓ postinstall préparé${NC}"; echo ""

# ============================================================================
# Construction du .pkg (pkgbuild stub + productbuild distribution)
# ============================================================================
echo -e "${BLUE}[*] Construction du PKG...${NC}"
mkdir -p "$DOWNLOAD_DIR" "$EMPTY_PAYLOAD_ROOT"
rm -f "$OUTPUT_PKG"
chmod +x "$SCRIPTS_DIR/postinstall"

COMPONENT_PKG="$BUILD_DIR/component.pkg"
pkgbuild \
    --identifier "$PKG_IDENTIFIER" \
    --version "$LATEST_VERSION" \
    --root "$EMPTY_PAYLOAD_ROOT" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG" > /dev/null

DIST_XML="$BUILD_DIR/distribution.xml"
cat > "$DIST_XML" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Carbon Copy Cloner</title>
    <pkg-ref id="$PKG_IDENTIFIER"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <choices-outline><line choice="default"><line choice="$PKG_IDENTIFIER"/></line></choices-outline>
    <choice id="default"/>
    <choice id="$PKG_IDENTIFIER" visible="false"><pkg-ref id="$PKG_IDENTIFIER"/></choice>
    <pkg-ref id="$PKG_IDENTIFIER" version="$LATEST_VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution "$DIST_XML" --package-path "$BUILD_DIR" "$OUTPUT_PKG" > /dev/null
echo -e "${GREEN}  ✓ PKG construit : $OUTPUT_PKG${NC}"; echo ""


# ============================================================================
# Écrit (ou remplace) les scripts install/uninstall Fleet dans le repo, puis
# ils seront commités par l'étape de publication. Contenu embarqué tel quel.
# ============================================================================
mkdir -p "$SOFTWARE_DIR"

echo -e "${BLUE}[*] Écriture de install_carbon_copy_cloner.sh...${NC}"
cat > "$INSTALL_SCRIPT" << 'FPF_INSTALL_EOF'
#!/bin/bash
# Script d'installation Fleet — Carbon Copy Cloner
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/carbon_copy_cloner_install.log"
APP_PATH="/Applications/Carbon Copy Cloner.app"
EXPECTED_TEAM_ID="L4F2DED5Q7"
EXPECTED_BUNDLE_ID="com.bombich.ccc"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install Carbon Copy Cloner ==="



DOWNLOAD_URL=$(curl -s -L -w '%{url_effective}' -o /dev/null "https://api.bombich.com/download/ccc?v=ccc7")

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }




EXDIR="$TEMP_DIR/extract"; mkdir -p "$EXDIR"
ditto -x -k "$ART" "$EXDIR" 2>/dev/null || unzip -q "$ART" -d "$EXDIR"
SRC=$(find "$EXDIR" -maxdepth 2 -name "*.app" | head -n 1)

[ -n "$SRC" ] && [ -d "$SRC" ] || { log "[ERROR] .app introuvable dans l'artefact"; exit 1; }

codesign --verify --deep --strict "$SRC" 2>&1 | tee -a "$LOG" || { log "[ERROR] codesign invalide"; exit 1; }


TID=$(codesign -dvv "$SRC" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
[ "$TID" = "$EXPECTED_TEAM_ID" ] || { log "[ERROR] TeamID inattendu : $TID (attendu $EXPECTED_TEAM_ID)"; exit 1; }
log "TeamID OK ($TID)"


spctl -a -vv -t install "$SRC" 2>&1 | tee -a "$LOG" || log "[WARN] notarisation non confirmée"


osascript -e 'quit app "Carbon Copy Cloner"' 2>/dev/null || pkill -f "Carbon Copy Cloner" 2>/dev/null || true

[ -d "$APP_PATH" ] && rm -rf "$APP_PATH"
ditto "$SRC" "$APP_PATH"
log "App copiée dans $APP_PATH"




log "=== Install terminée ==="
exit 0

FPF_INSTALL_EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ $INSTALL_SCRIPT${NC}"


echo -e "${BLUE}[*] Écriture de uninstall_carbon_copy_cloner.sh...${NC}"
cat > "$UNINSTALL_SCRIPT" << 'FPF_UNINSTALL_EOF'
#!/bin/bash

set -uo pipefail

LOG="/var/log/carbon_copy_cloner_uninstall.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== Carbon Copy Cloner uninstall started ==="

# --- 1. Quitter CCC s'il tourne ---
if pgrep -x "Carbon Copy Cloner" > /dev/null; then
    log "Quitting Carbon Copy Cloner..."
    osascript -e 'tell application "Carbon Copy Cloner" to quit' 2>/dev/null || true
    sleep 3
    pkill -9 -x "Carbon Copy Cloner" 2>/dev/null || true
fi

# --- 2. Désactiver et supprimer le privileged helper ---
# CCC installe un LaunchDaemon en root pour ses opérations système.
# Le nom exact peut varier selon la version, on couvre les cas connus.
HELPER_PLISTS=(
    "/Library/LaunchDaemons/com.bombich.ccchelper.plist"
    "/Library/LaunchDaemons/com.bombich.ccc.privilegedhelper.plist"
)

for plist in "${HELPER_PLISTS[@]}"; do
    if [ -f "$plist" ]; then
        log "Unloading helper: $plist"
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    fi
done

# Le binaire du helper
HELPER_BINARIES=(
    "/Library/PrivilegedHelperTools/com.bombich.ccchelper"
    "/Library/PrivilegedHelperTools/com.bombich.ccc.privilegedhelper"
)

for binary in "${HELPER_BINARIES[@]}"; do
    if [ -f "$binary" ]; then
        log "Removing helper binary: $binary"
        rm -f "$binary"
    fi
done

# --- 3. Supprimer l'app ---
APP_PATH="/Applications/Carbon Copy Cloner.app"
if [ -d "$APP_PATH" ]; then
    log "Removing $APP_PATH"
    rm -rf "$APP_PATH"
fi

# --- 4. Supprimer les preferences système ---
log "Removing system preferences..."
rm -f /Library/Preferences/com.bombich.ccc.plist
rm -f /Library/Preferences/com.bombich.ccchelper.plist

# --- 5. Supprimer les fichiers de support système ---
log "Removing system support files..."
rm -rf "/Library/Application Support/com.bombich.ccc"
rm -rf "/Library/Logs/CCC"

# --- 6. Supprimer les fichiers de support et prefs de chaque utilisateur ---
# CCC stocke des données dans le profil de chaque utilisateur du Mac
log "Removing per-user data..."
for user_home in /Users/*/; do
    user=$(basename "$user_home")
    
    # Skip les comptes système et invités
    case "$user" in
        Shared|Guest|.localized) continue ;;
    esac
    
    if [ ! -d "$user_home" ]; then
        continue
    fi
    
    log "  Cleaning user: $user"
    rm -rf "$user_home/Library/Application Support/com.bombich.ccc" 2>/dev/null || true
    rm -rf "$user_home/Library/Application Support/Carbon Copy Cloner" 2>/dev/null || true
    rm -rf "$user_home/Library/Caches/com.bombich.ccc" 2>/dev/null || true
    rm -f "$user_home/Library/Preferences/com.bombich.ccc.plist" 2>/dev/null || true
    rm -rf "$user_home/Library/Logs/CCC" 2>/dev/null || true
done

# --- 7. Forget les receipts pkg ---
# Pour que pkgutil --pkgs ne liste plus CCC
log "Forgetting pkg receipts..."
pkgutil --forget com.bombich.ccc.pkg 2>/dev/null || true
pkgutil --forget com.bombich.ccc 2>/dev/null || true

log "=== Uninstall complete ==="
exit 0



FPF_UNINSTALL_EOF
chmod +x "$UNINSTALL_SCRIPT"
echo -e "${GREEN}  ✓ $UNINSTALL_SCRIPT${NC}"

echo ""


# ============================================================================
# SHA256 → YAML Fleet → GitHub Release → commit/push YAML
# ============================================================================
echo -e "${BLUE}[*] Calcul SHA256 + mise à jour du YAML Fleet...${NC}"
SHA256=$(shasum -a 256 "$OUTPUT_PKG" | cut -d' ' -f1)
echo -e "${GREEN}  ✓ SHA256 : $SHA256${NC}"

# Met à jour hash_sha256 et version dans le YAML (créé s'il manque par le builder appelant).
if [ -f "$YAML_FILE" ]; then
    /usr/bin/sed -i '' -E "s/^( *hash_sha256: *).*/\1$SHA256/" "$YAML_FILE" 2>/dev/null || \
        sed -i -E "s/^( *hash_sha256: *).*/\1$SHA256/" "$YAML_FILE"
    /usr/bin/sed -i '' -E "s/^( *version: *).*/\1\"$LATEST_VERSION\"/" "$YAML_FILE" 2>/dev/null || \
        sed -i -E "s/^( *version: *).*/\1\"$LATEST_VERSION\"/" "$YAML_FILE"
fi
echo ""

echo -e "${BLUE}[*] Publication GitHub Release (tag: $RELEASE_TAG)...${NC}"
if ! command -v gh >/dev/null 2>&1; then echo -e "${RED}[ERROR] gh CLI requis${NC}"; exit 1; fi
# Crée la release si absente, puis upload (clobber pour remplacer l'ancien pkg).
gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1 || \
    gh release create "$RELEASE_TAG" --repo "$REPO" --title "$RELEASE_TAG" --notes "Auto-généré" >/dev/null
gh release upload "$RELEASE_TAG" "$OUTPUT_PKG" --repo "$REPO" --clobber >/dev/null
echo -e "${GREEN}  ✓ PKG uploadé : $PKG_URL${NC}"

# On ne versionne PAS le .pkg dans Git : on le supprime localement.
rm -f "$OUTPUT_PKG"
echo ""

echo -e "${BLUE}[*] Commit du YAML (anti race-condition : pkg déjà en ligne)...${NC}"
cd "$REPO_ROOT"
git add "lib/macos/software/carbon_copy_cloner.yml" "lib/macos/software/install_carbon_copy_cloner.sh" "lib/macos/software/uninstall_carbon_copy_cloner.sh"

if git diff --cached --quiet; then
    echo -e "${YELLOW}  Aucun changement à committer.${NC}"
else
    git commit -m "Carbon Copy Cloner → $LATEST_VERSION (auto)" >/dev/null
    # Push automatique (désactivable avec FPF_NO_PUSH=1)
    if [ "${FPF_NO_PUSH:-}" = "1" ]; then
        echo -e "${YELLOW}  Commit local (push désactivé via FPF_NO_PUSH=1).${NC}"
    else
        git push origin HEAD && echo -e "${GREEN}  ✓ Commit poussé sur origin${NC}"
    fi
fi

# Sortie GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "version=$LATEST_VERSION"; echo "sha256=$SHA256"; } >> "$GITHUB_OUTPUT"
fi
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ✓ Carbon Copy Cloner $LATEST_VERSION prêt pour Fleet${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"

