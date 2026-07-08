#!/bin/bash
# Fleet passe le chemin du PKG via $INSTALLER_PATH.
# App interne "Comparateur Listes" (build universel, ad-hoc, non notarisee).
installer -pkg "$INSTALLER_PATH" -target /

# App non notarisee : on retire l'attribut quarantine par securite pour eviter
# tout blocage Gatekeeper (une install MDM ne pose normalement pas de quarantine,
# c'est une ceinture+bretelles).
xattr -dr com.apple.quarantine "/Applications/ComparateurListes.app" 2>/dev/null || true
exit 0
