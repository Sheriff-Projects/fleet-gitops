#!/bin/bash
# Fleet passe le chemin du PKG via $INSTALLER_PATH.
#
# Ce PKG est le package "Self-Service" Creative Cloud Desktop genere dans
# l'Adobe Admin Console (Packages > Create a Package > Self-Service), avec
# l'option "Allow non-admins to update and install apps" ACTIVEE : nos
# utilisateurs finaux sont standard (non-admin), il leur faut ce build pour
# pouvoir installer Photoshop & co depuis l'onglet Apps de CC Desktop.
installer -pkg "$INSTALLER_PATH" -target /
