#!/bin/bash
 
# Utilisateur actuellement connecté à la console
username=$(stat -f%Su /dev/console)
 
# Pas d'utilisateur réel (login window, root) → on sort
if [ -z "$username" ] || [ "$username" = "root" ] || [ "$username" = "loginwindow" ] || [ "$username" = "_mbsetupuser" ]; then
  echo "Aucun utilisateur console valide ($username) → abandon."
  exit 0
fi
 
# Si l'utilisateur est admin → rien à faire (le test "standard" est ici)
if id -Gn "$username" 2>/dev/null | grep -qw admin; then
  echo "$username est admin → aucune modification nécessaire."
  exit 0
fi
 
# Utilisateur standard → on accorde le droit au session-owner
security authorizationdb read com.bombich.ccc.helper > /tmp/ccc.plist
defaults write /tmp/ccc "authenticate-user" -bool NO
defaults write /tmp/ccc "session-owner" -bool YES
plutil -convert xml1 /tmp/ccc.plist
security authorizationdb write com.bombich.ccc.helper < /tmp/ccc.plist
security authorize -ud com.bombich.ccc.helper
 
echo "Droit com.bombich.ccc.helper accordé au session-owner pour $username."