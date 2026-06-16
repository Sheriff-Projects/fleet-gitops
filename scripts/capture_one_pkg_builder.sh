#!/bin/bash
# ============================================================================
# Capture One — PKG Builder  (généré par Fleet Package Factory)
# Type d'install : app_in_dmg | Mode : fleet_install_script
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

# --- Configuration (issue de la fiche capture_one.yml) ---
REPO="Sheriff-Projects/fleet-gitops"
SLUG="capture_one"
RELEASE_TAG="capture_one"
DOWNLOAD_DIR="$REPO_ROOT/lib/macos/download"
OUTPUT_PKG="$DOWNLOAD_DIR/capture_one.pkg"
SOFTWARE_DIR="$REPO_ROOT/lib/macos/software"
YAML_FILE="$REPO_ROOT/lib/macos/software/capture_one.yml"
INSTALL_SCRIPT="$SOFTWARE_DIR/install_capture_one.sh"
UNINSTALL_SCRIPT="$SOFTWARE_DIR/uninstall_capture_one.sh"
PKG_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${SLUG}.pkg"
PKG_IDENTIFIER="com.captureone.captureone16"
EXPECTED_TEAM_ID="5WTDB5F65L"
EXPECTED_BUNDLE_ID="com.captureone.captureone16"
APP_PATH="/Applications/Capture One.app"

BUILD_DIR=$(mktemp -d)
SCRIPTS_DIR="$BUILD_DIR/scripts"
EMPTY_PAYLOAD_ROOT="$BUILD_DIR/empty-root"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
printf  "${BLUE}║ %-44s ║${NC}\n" "Capture One — PKG Builder"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
echo "Repo root: $REPO_ROOT"; echo ""

# ============================================================================
# Détection de la dernière version — stratégie : xml_path
# ============================================================================
echo -e "${BLUE}[*] Détection de la dernière version...${NC}"


# XML générique : chemins version + URL (style json_path). Namespaces ignorés,
# attributs supportés via .../@attr. Le 1er élément trouvé = le plus récent.
XML_TMP=$(mktemp)
curl -sSL --fail --max-time 30 "https://www.captureone.com/update/capture-one-mac.xml" -o "$XML_TMP" || { echo -e "${RED}[ERROR] Fetch XML échoué${NC}"; exit 1; }
PARSED=$(python3 - "$XML_TMP" "item/title" "item/enclosure/@url" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
fn, vpath, upath = sys.argv[1], sys.argv[2], sys.argv[3]
root = ET.parse(fn).getroot()
def ln(t): return t.split('}')[-1]
def resolve(path):
    attr = None
    if '/@' in path:
        path, attr = path.rsplit('/@', 1)
    parts = [p.split(':')[-1] for p in path.split('/') if p]
    nodes = [root]
    for part in parts:
        nodes = [c for n in nodes for c in n.iter() if c is not n and ln(c.tag) == part]
        if not nodes:
            return None, attr
    return nodes[0], attr
def val(el, attr):
    if el is None:
        return ''
    if attr:
        return next((v for k, v in el.attrib.items() if ln(k) == attr), '')
    return (el.text or '').strip()
ve, va = resolve(vpath)
ue, ua = resolve(upath)
print(val(ve, va))
print(val(ue, ua))
PYEOF
)
RAW_VERSION=$(printf '%s\n' "$PARSED" | sed -n 1p)
DOWNLOAD_URL=$(printf '%s\n' "$PARSED" | sed -n 2p)
rm -f "$XML_TMP"


if [ -z "${RAW_VERSION:-}" ] || [ "$RAW_VERSION" = "null" ]; then echo -e "${RED}[ERROR] Version introuvable${NC}"; exit 1; fi

LATEST_VERSION="$RAW_VERSION"


echo -e "${GREEN}  ✓ Version : $LATEST_VERSION${NC}"
echo -e "${GREEN}  ✓ URL     : $DOWNLOAD_URL${NC}"
echo -e "${GREEN}  ✓ Bundle  : $PKG_IDENTIFIER${NC}"
echo ""

# ============================================================================
# Génération du postinstall embarqué dans le PKG
# Règle d'échappement heredoc : $VAR = build-time (valeur figée) ; \$VAR = runtime (Mac client)
# ============================================================================
mkdir -p "$SCRIPTS_DIR"


# --- PKG stub : postinstall no-op (vraie install dans install_capture_one.sh) ---
cat > "$SCRIPTS_DIR/postinstall" << EOF
#!/bin/bash
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Capture One stub PKG installé (no-op)" >> /var/log/capture_one_install.log
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
    <title>Capture One</title>
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

echo -e "${BLUE}[*] Écriture de install_capture_one.sh...${NC}"
cat > "$INSTALL_SCRIPT" << 'FPF_INSTALL_EOF'
#!/bin/bash
# Script d'installation Fleet — Capture One
# Exécuté en root par Fleet. Re-détecte la version au runtime (URL toujours fraîche).
set -euo pipefail
LOG="/var/log/capture_one_install.log"
APP_PATH="/Applications/Capture One.app"
EXPECTED_TEAM_ID="5WTDB5F65L"
EXPECTED_BUNDLE_ID="com.captureone.captureone16"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }
TEMP_DIR=$(mktemp -d)
cleanup() { hdiutil detach "$TEMP_DIR/mnt" -force -quiet 2>/dev/null || true; rm -rf "$TEMP_DIR"; }
trap cleanup EXIT
log "=== Install Capture One ==="



XML_TMP=$(mktemp)
curl -sSL --fail "https://www.captureone.com/update/capture-one-mac.xml" -o "$XML_TMP"
DOWNLOAD_URL=$(python3 - "$XML_TMP" "item/enclosure/@url" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
fn, upath = sys.argv[1], sys.argv[2]
root = ET.parse(fn).getroot()
def ln(t): return t.split('}')[-1]
attr = None
if '/@' in upath:
    upath, attr = upath.rsplit('/@', 1)
nodes = [root]
for part in [p.split(':')[-1] for p in upath.split('/') if p]:
    nodes = [c for n in nodes for c in n.iter() if c is not n and ln(c.tag) == part]
    if not nodes:
        print(''); raise SystemExit
el = nodes[0]
print(next((v for k, v in el.attrib.items() if ln(k) == attr), '') if attr else (el.text or '').strip())
PYEOF
)
rm -f "$XML_TMP"

log "URL : $DOWNLOAD_URL"
ART="$TEMP_DIR/artifact"

curl -sSL --fail --max-time 1800 "$DOWNLOAD_URL" -o "$ART" || { log "[ERROR] download échoué"; exit 1; }




MNT="$TEMP_DIR/mnt"; mkdir -p "$MNT"
hdiutil attach "$ART" -mountpoint "$MNT" -nobrowse -quiet || { log "[ERROR] montage DMG échoué"; exit 1; }
SRC=$(find "$MNT" -maxdepth 2 -name "*.app" | head -n 1)

[ -n "$SRC" ] && [ -d "$SRC" ] || { log "[ERROR] .app introuvable dans l'artefact"; exit 1; }

codesign --verify --deep --strict "$SRC" 2>&1 | tee -a "$LOG" || { log "[ERROR] codesign invalide"; exit 1; }


TID=$(codesign -dvv "$SRC" 2>&1 | grep "TeamIdentifier=" | cut -d= -f2 || echo "")
[ "$TID" = "$EXPECTED_TEAM_ID" ] || { log "[ERROR] TeamID inattendu : $TID (attendu $EXPECTED_TEAM_ID)"; exit 1; }
log "TeamID OK ($TID)"


spctl -a -vv -t install "$SRC" 2>&1 | tee -a "$LOG" || log "[WARN] notarisation non confirmée"


osascript -e 'quit app "Capture One"' 2>/dev/null || pkill -f "Capture One" 2>/dev/null || true

[ -d "$APP_PATH" ] && rm -rf "$APP_PATH"
ditto "$SRC" "$APP_PATH"
log "App copiée dans $APP_PATH"




log "=== Install terminée ==="
exit 0

FPF_INSTALL_EOF
chmod +x "$INSTALL_SCRIPT"
echo -e "${GREEN}  ✓ $INSTALL_SCRIPT${NC}"


echo -e "${BLUE}[*] Écriture de uninstall_capture_one.sh...${NC}"
cat > "$UNINSTALL_SCRIPT" << 'FPF_UNINSTALL_EOF'
#!/bin/bash
set -o pipefail
# 3. Fermeture agressive
pkill -9 -f "com.captureone"*
sleep 3

# 2. Retirer du Dock pour tous les utilisateurs

for user_home in /Users/*; do
    user=$(basename "$user_home")
    [[ "$user" == "Shared" || "$user" == "Guest" || "$user" == ".localized" ]] && continue
    [ ! -d "$user_home" ] && continue
    
    DOCK_PLIST="$user_home/Library/Preferences/com.apple.dock.plist"
    [ ! -f "$DOCK_PLIST" ] && continue
    
    USER_UID=$(id -u "$user" 2>/dev/null) || continue
    
    # Compter les entrées persistent-apps
    PLIST_COUNT=$(sudo -u "$user" /usr/libexec/PlistBuddy -c "Print :persistent-apps" "$DOCK_PLIST" 2>/dev/null | grep -c "Dict {" || echo 0)
    
    if [ "$PLIST_COUNT" -eq 0 ]; then
        continue
    fi
    
    # Parcourir les indices à L'ENVERS pour pouvoir supprimer sans casser la numérotation
    REMOVED=0
    for ((i=PLIST_COUNT-1; i>=0; i--)); do
        APP_URL=$(sudo -u "$user" /usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$DOCK_PLIST" 2>/dev/null || echo "")
        
        # Match sur le path Capture One (URL-encoded ou normal)
        if [[ "$APP_URL" == *"Capture%20One"* ]] || [[ "$APP_URL" == *"Capture One"* ]]; then

            sudo -u "$user" /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$DOCK_PLIST"
            REMOVED=$((REMOVED + 1))
        fi
    done
    
    # Recharger le Dock pour cet user (s'il y a eu des suppressions)
    if [ "$REMOVED" -gt 0 ]; then
        sudo -u "$user" launchctl asuser "$USER_UID" killall Dock 2>/dev/null || true

    fi
done

echo "--- Désinstallation forcée de Capture One ---"


# 4. Liste des cibles (Notez qu'on ne met pas de guillemets autour du tableau pour permettre l'expansion)
TARGETS=(
    "/Applications/Capture One"*.app
    "/Users/Shared/Capture One"
    "$USER_HOME/Library/Application Support/Capture One"
    "$USER_HOME/Library/Caches/com.captureone.captureone"*
    "$USER_HOME/Library/Logs/com.captureone."*
    "$USER_HOME/Library/Preferences/com.captureone.captureone"*".plist"
)



# 5. Suppression des dossiers système (Var Folders)
find /private/var/folders -type d -name "*com.captureone*" -exec rm -rf {} + 2>/dev/null

# 6. Suppression des fichiers avec gestion rigoureuse des espaces
for item in "${TARGETS[@]}"; do
    # On utilise un test d'existence sur chaque élément trouvé par le joker
    if [ -e "$item" ]; then
        echo "Suppression : $item"
        rm -rf "$item"
    fi
done

echo "--- Désinstallation terminée ---"


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
git add "lib/macos/software/capture_one.yml" "lib/macos/software/install_capture_one.sh" "lib/macos/software/uninstall_capture_one.sh"

if git diff --cached --quiet; then
    echo -e "${YELLOW}  Aucun changement à committer.${NC}"
else
    git commit -m "Capture One → $LATEST_VERSION (auto)" >/dev/null
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
echo -e "${GREEN}  ✓ Capture One $LATEST_VERSION prêt pour Fleet${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"

