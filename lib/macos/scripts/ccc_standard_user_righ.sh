#!/bin/bash

username=$(stat -f%Su /dev/console)
security authorizationdb read com.bombich.ccc.helper > /tmp/ccc.plist
defaults write /tmp/ccc "authenticate-user" -bool NO
defaults write /tmp/ccc "session-owner" -bool YES
plutil -convert xml1 /tmp/ccc.plist
security authorizationdb write com.bombich.ccc.helper < /tmp/ccc.plist
security authorize -ud com.bombich.ccc.helper