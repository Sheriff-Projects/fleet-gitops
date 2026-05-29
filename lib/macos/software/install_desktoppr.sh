#!/bin/bash
# Fleet passes the PKG path via $INSTALLER_PATH
# This just runs the PKG, which contains the real install logic as postinstall script
installer -pkg "$INSTALLER_PATH" -target /