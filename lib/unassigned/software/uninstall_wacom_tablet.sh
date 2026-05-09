#!/bin/bash
#
# Script de désinstallation du pilote Wacom Tablet
# Reconstitué à partir des scripts preinstall/postinstall du .pkg
#
# Usage : sudo ./uninstall_wacom.sh
#

set -u  # erreur si variable non définie (mais on continue sur erreur de commande)

# ============================================================================
# Vérifications préalables
# ============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ce script doit être exécuté avec sudo."
    echo "   Relance avec : sudo $0"
    exit 1
fi

# Récupère l'utilisateur courant (celui qui a lancé sudo)
REAL_USER="${SUDO_USER:-$USER}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo "⚠️  Impossible de déterminer l'utilisateur réel. Lance via sudo depuis ton compte normal."
    exit 1
fi
REAL_HOME=$(eval echo ~"$REAL_USER")

echo "================================================================"
echo "  Désinstallation du pilote Wacom Tablet"
echo "================================================================"
echo "  Utilisateur cible : $REAL_USER"
echo "  Dossier home      : $REAL_HOME"
echo ""
read -p "Continuer ? (o/N) " confirm
if [[ ! "$confirm" =~ ^[oOyY]$ ]]; then
    echo "Annulé."
    exit 0
fi
echo ""

# ============================================================================
# 1. Tuer tous les processus Wacom en cours
# ============================================================================
echo "▶ Étape 1/6 : Arrêt des processus Wacom..."

ProgramList=(
    "WacomTabletDriver"
    "WacomTouchDriver"
    "TabletDriver"
    "Wacom Tablet Utility"
    "Wacom Desktop Center"
    "Wacom Center"
    "Wacom Experience Program"
    "UpgradeHelper"
)

for aProgram in "${ProgramList[@]}"; do
    PIDS=$(pgrep -f "$aProgram" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        for aPID in $PIDS; do
            echo "  • kill $aProgram (PID $aPID)"
            kill -9 "$aPID" 2>/dev/null || true
        done
    fi
done
sleep 1

# ============================================================================
# 2. Décharger les LaunchAgents (services utilisateur)
# ============================================================================
echo ""
echo "▶ Étape 2/6 : Déchargement des LaunchAgents..."

AgentList=(
    "/Library/LaunchAgents/com.wacom.DataStoreMgr.plist"
    "/Library/LaunchAgents/com.wacom.wacomtablet.plist"
    "/Library/LaunchAgents/com.wacom.DisplayMgr.plist"
    "/Library/LaunchAgents/com.wacom.IOManager.plist"
)

for anAgent in "${AgentList[@]}"; do
    if [ -e "$anAgent" ]; then
        echo "  • unload $anAgent"
        sudo -u "$REAL_USER" launchctl unload "$anAgent" 2>/dev/null || true
    fi
done
sleep 1

# ============================================================================
# 3. Décharger les LaunchDaemons (services système)
# ============================================================================
echo ""
echo "▶ Étape 3/6 : Déchargement des LaunchDaemons..."

DaemonList=(
    "/Library/LaunchDaemons/com.wacom.DisplayHelper.plist"
    "/Library/LaunchDaemons/com.wacom.displayhelper.plist"
    "/Library/LaunchDaemons/com.wacom.UpdateHelper.plist"
    "/Library/LaunchDaemons/com.wacom.TabletHelper.plist"
)

for aDaemon in "${DaemonList[@]}"; do
    if [ -e "$aDaemon" ]; then
        echo "  • unload $aDaemon"
        launchctl unload "$aDaemon" 2>/dev/null || true
    fi
done
sleep 1

# ============================================================================
# 4. Décharger les Kexts (extensions kernel) — peut échouer sur macOS récent
# ============================================================================
echo ""
echo "▶ Étape 4/6 : Déchargement des extensions kernel..."

KextList=(
    "com.Wacom.iokit.TabletDriver"
    "com.wacom.kext.wacomtablet"
    "com.wacom.kext.ftdi"
    "com.wacom.WacomTabletHIDDevice"
)

for aKext in "${KextList[@]}"; do
    echo "  • kextunload $aKext"
    /sbin/kextunload -m "$aKext" 2>/dev/null || true
done

# ============================================================================
# 5. Suppression des fichiers et dossiers
# ============================================================================
echo ""
echo "▶ Étape 5/6 : Suppression des fichiers..."

FilesToRemove=(
    # LaunchAgents et LaunchDaemons
    "/Library/LaunchAgents/com.wacom.DataStoreMgr.plist"
    "/Library/LaunchAgents/com.wacom.wacomtablet.plist"
    "/Library/LaunchAgents/com.wacom.DisplayMgr.plist"
    "/Library/LaunchAgents/com.wacom.IOManager.plist"
    "/Library/LaunchDaemons/com.wacom.DisplayHelper.plist"
    "/Library/LaunchDaemons/com.wacom.displayhelper.plist"
    "/Library/LaunchDaemons/com.wacom.UpdateHelper.plist"
    "/Library/LaunchDaemons/com.wacom.TabletHelper.plist"

    # Applications et dossiers principaux
    "/Applications/Wacom Tablet.localized"
    "/Applications/WacomTablet"
    "/Applications/Tablet.localized"
    "/Library/Application Support/Tablet"

    # PreferencePanes (anciens et récents)
    "/Library/PreferencePanes/WacomTablet.prefPane"
    "/Library/PreferencePanes/Wacom Tablet.prefPane"
    "/Library/PreferencePanes/Pen Tablet.prefPane"
    "/Library/PreferencePanes/Tablet.prefPane"

    # PrivilegedHelperTools
    "/Library/PrivilegedHelperTools/com.wacom.TabletHelper.app"
    "/Library/PrivilegedHelperTools/com.wacom.IOmanager.app"

    # Extensions kernel
    "/Library/Extensions/TabletDriver.kext"
    "/Library/Extensions/WacomTablet.kext"
    "/System/Library/Extensions/TabletDriver.kext"
    "/System/Library/Extensions/WacomTablet.kext"

    # Plugins navigateur (anciens)
    "/Library/Internet Plug-Ins/WacomTabletPlugin.plugin"
    "/Library/Internet Plug-Ins/WacomSafari.plugin"

    # Receipts et préférences anciennes
    "/Library/Preferences/Tablet"
    "/Library/Receipts/InstallConsumerTablet.pkg"
    "/Library/Receipts/InstallProTablet.pkg"
    "/Library/Receipts/InstallSemiproTablet.pkg"
    "/Library/Receipts/Wacom Tablet Docs.txt"
    "/Library/Receipts/TabletDocs.txt"

    # StartupItems (très anciens)
    "/Library/StartupItems/Tablet"

    # Fichiers utilisateur
    "$REAL_HOME/Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver"
    "$REAL_HOME/Library/Group Containers/group.EG27766DY7.com.wacom.WacomTabletDriver"
    "$REAL_HOME/Library/Group Containers/group.com.wacom.TabletDriver"
    "$REAL_HOME/Library/Containers/com.wacom.wacomtablet"
    "$REAL_HOME/Library/Application Support/Wacom"
    "$REAL_HOME/Library/Preferences/com.wacom.Wacom-Desktop-Center.plist"
)

for aFile in "${FilesToRemove[@]}"; do
    if [ -e "$aFile" ] || [ -L "$aFile" ]; then
        echo "  • rm $aFile"
        rm -rf "$aFile" 2>/dev/null || echo "    ⚠️  échec de suppression"
    fi
done

# Suppression supplémentaire pour TOUS les utilisateurs (pas seulement le courant)
echo ""
echo "  Nettoyage des dossiers utilisateurs..."
for userdir in /Users/*; do
    [ -d "$userdir" ] || continue
    [ "$(basename "$userdir")" = "Shared" ] && continue

    for path in \
        "$userdir/Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver" \
        "$userdir/Library/Group Containers/group.EG27766DY7.com.wacom.WacomTabletDriver" \
        "$userdir/Library/Group Containers/group.com.wacom.TabletDriver" \
        "$userdir/Library/Containers/com.wacom.wacomtablet" \
        "$userdir/Library/Application Support/Wacom" \
        "$userdir/Library/Preferences/com.wacom.Wacom-Desktop-Center.plist"
    do
        if [ -e "$path" ] || [ -L "$path" ]; then
            echo "  • rm $path"
            rm -rf "$path" 2>/dev/null || true
        fi
    done
done

# ============================================================================
# 6. Suppression des receipts pkgutil
# ============================================================================
echo ""
echo "▶ Étape 6/6 : Suppression des receipts pkgutil..."

# Liste tous les receipts Wacom et les efface
WacomPkgs=$(pkgutil --pkgs | grep -i wacom || true)
if [ -n "$WacomPkgs" ]; then
    while IFS= read -r pkg; do
        echo "  • forget $pkg"
        pkgutil --forget "$pkg" 2>/dev/null || true
    done <<< "$WacomPkgs"
else
    echo "  (aucun receipt Wacom trouvé)"
fi

echo ""
echo "================================================================"
echo "  ✅ Désinstallation terminée."
echo ""
echo "  Recommandations :"
echo "    • Redémarre le Mac pour que tout soit pris en compte."
echo "    • Si une extension kernel a refusé de se décharger, le"
echo "      redémarrage la déchargera proprement."
echo "================================================================"