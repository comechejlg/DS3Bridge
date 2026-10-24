#!/bin/zsh
# Installs the DS3Bridge virtual keyboard as a system service (starts with the Mac)
# and creates DS3Bridge.app in Applications. Asks for your password ONCE.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ME_UID=$(id -u)
DAEMON='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon'
[ -x "$ROOT/bin/vhidkbd" ] || { echo "Build first with ./build.sh"; exit 1; }
[ -x "$DAEMON" ] || { echo "Install the driver first with 'Install Karabiner driver'"; exit 1; }
echo "Installing the DS3Bridge service (you will be asked for your password)..."
sudo -v

# The binary goes to a root-only folder: a root service must not run files the user can edit.
sudo mkdir -p /usr/local/libexec/ds3bridge
sudo cp "$ROOT/bin/vhidkbd" /usr/local/libexec/ds3bridge/vhidkbd
sudo chown -R root:wheel /usr/local/libexec/ds3bridge
sudo chmod 755 /usr/local/libexec/ds3bridge /usr/local/libexec/ds3bridge/vhidkbd

sudo tee /Library/LaunchDaemons/com.ds3bridge.karabiner-daemon.plist >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ds3bridge.karabiner-daemon</string>
  <key>ProgramArguments</key><array><string>$DAEMON</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST

# The socket is owned by your user with mode 0600: only you can send keys to the virtual keyboard.
sudo tee /Library/LaunchDaemons/com.ds3bridge.vhidkbd.plist >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ds3bridge.vhidkbd</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/libexec/ds3bridge/vhidkbd</string>
    <string>/var/run/ds3bridge.sock</string>
    <string>$ME_UID</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/ds3bridge-vhidkbd.log</string>
  <key>StandardErrorPath</key><string>/var/log/ds3bridge-vhidkbd.log</string>
</dict></plist>
PLIST

for s in karabiner-daemon vhidkbd; do
  sudo launchctl bootout system/com.ds3bridge.$s 2>/dev/null || true
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.ds3bridge.$s.plist
done

# App in Applications that opens the launcher
rm -rf /Applications/DS3Bridge.app
osacompile -o /Applications/DS3Bridge.app \
  -e "do shell script \"open -a Terminal \" & quoted form of \"$ROOT/scripts/Start DS3Bridge.command\""

sleep 3
if [ -S /var/run/ds3bridge.sock ]; then
  echo; echo "✅ Installed. Open DS3Bridge from Applications: no password needed from now on."
else
  echo; echo "⚠️  The service has not created its socket yet. Check /var/log/ds3bridge-vhidkbd.log"
fi
read -k 1 "?Press any key to close..."
