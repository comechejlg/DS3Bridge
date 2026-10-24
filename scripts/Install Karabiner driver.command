#!/bin/zsh
# Downloads, verifies and installs the Karabiner virtual keyboard driver
# (Karabiner-DriverKit-VirtualHIDDevice, by pqrs.org / Fumihiko Takayama).
set -e
VER=8.2.0
TEAM=G43BCU2T37
PKG="/tmp/Karabiner-DriverKit-VirtualHIDDevice-$VER.pkg"
echo "Downloading Karabiner-DriverKit-VirtualHIDDevice $VER..."
curl -fsSL -o "$PKG" "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v$VER/Karabiner-DriverKit-VirtualHIDDevice-$VER.pkg"
echo "Checking signature and notarization..."
SIG="$(pkgutil --check-signature "$PKG")"
echo "$SIG" | grep -q "Developer ID Installer: Fumihiko Takayama ($TEAM)" || { echo "❌ Unexpected signature, not installing."; exit 1; }
echo "$SIG" | grep -q "trusted by the Apple notary service" || { echo "❌ Not notarized, not installing."; exit 1; }
echo "✅ Signature OK. Opening the installer: follow it (it will ask for your password)."
open -W "$PKG"
echo
echo "Activating the driver..."
/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate || true
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
echo
echo "Now go to System Settings → General → Login Items & Extensions → Driver Extensions (ⓘ)"
echo "and enable 'Karabiner-VirtualHIDDevice'. Then run 'Install service'."
read -k 1 "?Press any key to close..."
