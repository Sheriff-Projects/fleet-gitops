#!/bin/sh
#
# Install script — WallpaperFolderManager + ajout du dossier sp_wallpapers
# https://github.com/bartreardon/WallpaperFolderManager
#
# Tourne en root via Fleet. $INSTALLER_PATH = chemin du .pkg fourni par Fleet.
#

# Installe le pkg Fleet
installer -pkg "$INSTALLER_PATH" -target /

WALLPAPER_FOLDER="/Users/Shared/sp_wallpapers/"
WALLPAPER_PATH="/Users/Shared/sp_wallpapers/Wallpaper_Retina_Black_SHERIFF_PROJECTS.jpg"

# Vérifie que le dossier existe
if [ ! -d "$WALLPAPER_FOLDER" ]; then
  echo "Erreur : le dossier n'existe pas : $WALLPAPER_FOLDER"
  exit 1
fi

# Vérifie que le binaire est disponible
if [ ! -x "/usr/local/bin/wallpaper-folder" ]; then
  echo "Erreur : /usr/local/bin/wallpaper-folder introuvable ou non exécutable"
  exit 1
fi

# Récupère l'utilisateur actuellement connecté à la session graphique
LOGGED_IN_USER=$(/usr/bin/stat -f "%Su" /dev/console)
LOGGED_IN_UID=$(/usr/bin/id -u "$LOGGED_IN_USER")

if [ "$LOGGED_IN_USER" = "root" ] || [ -z "$LOGGED_IN_USER" ]; then
  echo "Erreur : aucun utilisateur graphique connecté"
  exit 1
fi

echo "Utilisateur connecté : $LOGGED_IN_USER"
echo "UID : $LOGGED_IN_UID"

# Ajoute le dossier dans les préférences Fond d'écran de l'utilisateur connecté
/bin/launchctl asuser "$LOGGED_IN_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" \
  /usr/local/bin/wallpaper-folder add "$WALLPAPER_FOLDER" --verbose

RESULT=$?

# Redémarre les services côté utilisateur
/bin/launchctl asuser "$LOGGED_IN_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" \
  /usr/bin/killall cfprefsd 2>/dev/null

/bin/launchctl asuser "$LOGGED_IN_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" \
  /usr/bin/killall WallpaperAgent 2>/dev/null

if [ "$RESULT" -ne 0 ]; then
  echo "Erreur : wallpaper-folder add a échoué"
  exit "$RESULT"
fi

echo "Dossier ajouté aux préférences Fond d'écran pour $LOGGED_IN_USER : $WALLPAPER_FOLDER"

/bin/launchctl asuser "$LOGGED_IN_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" \
  /usr/local/bin/desktoppr "$WALLPAPER_PATH"

/bin/launchctl asuser "$LOGGED_IN_UID" /usr/bin/sudo -u "$LOGGED_IN_USER" \
  /usr/local/bin/dark-mode

exit 0