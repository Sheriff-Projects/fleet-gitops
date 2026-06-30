#!/bin/bash
# Desinstallation best-effort de Creative Cloud Desktop.
# La desinstallation propre Adobe passe par le "Creative Cloud Uninstaller".
UNINSTALLER="/Applications/Utilities/Adobe Creative Cloud/Utils/Creative Cloud Uninstaller.app/Contents/MacOS/Creative Cloud Uninstaller"
if [ -x "$UNINSTALLER" ]; then
  "$UNINSTALLER" -u || true
fi
exit 0
