#!/bin/zsh
# Quita el servicio y la app de DS3Bridge. No desinstala el driver de Karabiner
# (para eso: /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager deactivate).
sudo -v || exit 1
for s in vhidkbd karabiner-daemon; do
  sudo launchctl bootout system/com.ds3bridge.$s 2>/dev/null
  sudo rm -f /Library/LaunchDaemons/com.ds3bridge.$s.plist
done
sudo rm -rf /usr/local/libexec/ds3bridge /var/run/ds3bridge.sock
rm -rf /Applications/DS3Bridge.app
echo "Servicio de DS3Bridge quitado."
read -k 1 "?Pulsa una tecla para cerrar..."
