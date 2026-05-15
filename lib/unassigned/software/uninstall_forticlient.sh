#!/bin/sh

OldUnInstaller="/Applications/FortiClientUninstaller.app/Contents/MacOS/Uninstall"
UnInstaller="/Applications/FortiClientUninstaller.app/Contents/Library/LaunchServices/com.fortinet.forticlient.uninstall_helper"

if [ -x "$UnInstaller" ]; then
    "$UnInstaller" upgrade-uninstall
elif [ -x "$OldUnInstaller" ]; then
    "$OldUnInstaller"
else
    echo "$(date) - Error: Uninstaller not found."
    exit 1
fi