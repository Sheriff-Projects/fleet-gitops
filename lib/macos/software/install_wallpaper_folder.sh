#!/bin/sh
#
# Install script — WallpaperFolderManager + ajout du dossier sp_wallpapers
# https://github.com/bartreardon/WallpaperFolderManager
#
# Tourne en root via Fleet. $INSTALLER_PATH = chemin du .pkg fourni par Fleet.
#

# Installe le pkg Fleet
installer -pkg "$INSTALLER_PATH" -target /

