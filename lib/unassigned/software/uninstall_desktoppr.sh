#!/bin/bash



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