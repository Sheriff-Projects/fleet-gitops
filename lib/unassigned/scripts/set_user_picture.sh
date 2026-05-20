#!/bin/bash
set -euo pipefail

FLAG_DIR="/var/db/sheriffprojects"
username=$(stat -f%Su /dev/console)
userPicture="/Users/Shared/Wallpapers_SP/sheriff_projects.jpg"

# Sortie propre si pas de user console valide -> Fleet relancera plus tard
if [ "$username" = "root" ] || [ "$username" = "_mbsetupuser" ] || [ "$username" = "loginwindow" ] || [ -z "$username" ]; then
    echo "Pas de user console valide ($username). Sortie, retry au prochain cycle."
    exit 1
fi

# Si deja applique pour ce user, on ne refait rien
mkdir -p "$FLAG_DIR"
if [ -f "$FLAG_DIR/.photo_applied_$username" ]; then
    echo "Photo deja appliquee pour $username."
    exit 0
fi

if [ ! -f "$userPicture" ]; then
    echo "Image introuvable : $userPicture"
    exit 1
fi

if ! id "$username" &>/dev/null; then
    echo "Utilisateur $username inexistant."
    exit 1
fi

dscl . delete /Users/"$username" Picture 2>/dev/null || true
dscl . delete /Users/"$username" JPEGPhoto 2>/dev/null || true

pictureImport="/Library/Caches/$username.picture.dsimport"
{
    printf '0x0A 0x5C 0x3A 0x2C dsRecTypeStandard:Users 2 dsAttrTypeStandard:RecordName externalbinary:dsAttrTypeStandard:JPEGPhoto\n'
    printf '%s:%s\n' "$username" "$userPicture"
} > "$pictureImport"

if dsimport "$pictureImport" /Local/Default M; then
    touch "$FLAG_DIR/.photo_applied_$username"
    echo "Photo importee avec succes pour $username."
    rm -f "$pictureImport"
    exit 0
else
    rm -f "$pictureImport"
    echo "Echec import."
    exit 1
fi