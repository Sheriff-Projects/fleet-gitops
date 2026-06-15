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
if [ -n "${FLEET_GITOPS_REPO_PATH:-}" ]; then
    REPO_ROOT="$FLEET_GITOPS_REPO_PATH"
else
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
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
YAML_FILE="$REPO_ROOT/lib/macos/software/capture_one.yml"
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
    echo -e "${YELLOW}  Commit créé localement. Ouvre une PR ou push manuellement.${NC}"
fi

# Sortie GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "version=$LATEST_VERSION"; echo "sha256=$SHA256"; } >> "$GITHUB_OUTPUT"
fi
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ✓ Capture One $LATEST_VERSION prêt pour Fleet${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"

