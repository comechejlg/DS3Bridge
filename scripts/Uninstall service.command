#!/bin/zsh
# Removes the DS3Bridge service (and the launcher app created by a source build). Does not uninstall the Karabiner driver
# (for that: /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager deactivate).
sudo -v || exit 1
for s in vhidkbd karabiner-daemon; do
  sudo launchctl bootout system/com.ds3bridge.$s 2>/dev/null
  sudo rm -f /Library/LaunchDaemons/com.ds3bridge.$s.plist
done
sudo rm -rf /usr/local/libexec/ds3bridge /var/run/ds3bridge.sock
# Only remove the small launcher app made by 'Install service' in a source build;
# the downloaded DS3Bridge.app (which has everything inside) is left for you to delete.
[ -d /Applications/DS3Bridge.app/Contents/Resources/DS3Bridge ] || rm -rf /Applications/DS3Bridge.app
echo "DS3Bridge service removed."
read -k 1 "?Press any key to close..."
