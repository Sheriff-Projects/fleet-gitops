#!/bin/sh
# https://github.com/bartreardon/WallpaperFolderManager

installer -pkg "$INSTALLER_PATH" -target /

LOGGED_USER=$(stat -f%Su /dev/console)



WALLPAPER_FOLDER="/Users/Shared/sp_wallpapers"

# Vérifie que le dossier existe
if [ ! -d "$WALLPAPER_FOLDER" ]; then
  echo "Erreur : le dossier n'existe pas : $WALLPAPER_FOLDER"
  exit 1
fi

# Ajoute le dossier dans les préférences Fond d'écran
sudo -u $LOGGED_USER wallpaper-folder add "$WALLPAPER_FOLDER" --verbose

# Redémarre les services nécessaires
killall cfprefsd 2>/dev/null
killall WallpaperAgent 2>/dev/null

echo "Dossier ajouté aux préférences Fond d'écran : $WALLPAPER_FOLDER"



