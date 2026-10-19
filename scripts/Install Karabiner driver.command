#!/bin/zsh
# Descarga, comprueba e instala el driver de teclado virtual de Karabiner
# (Karabiner-DriverKit-VirtualHIDDevice, de pqrs.org / Fumihiko Takayama).
set -e
VER=8.2.0
TEAM=G43BCU2T37
PKG="/tmp/Karabiner-DriverKit-VirtualHIDDevice-$VER.pkg"
echo "Descargando Karabiner-DriverKit-VirtualHIDDevice $VER..."
curl -fsSL -o "$PKG" "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v$VER/Karabiner-DriverKit-VirtualHIDDevice-$VER.pkg"
echo "Comprobando firma y notarización..."
SIG="$(pkgutil --check-signature "$PKG")"
echo "$SIG" | grep -q "Developer ID Installer: Fumihiko Takayama ($TEAM)" || { echo "❌ Firma inesperada, no se instala."; exit 1; }
echo "$SIG" | grep -q "trusted by the Apple notary service" || { echo "❌ No está notarizado, no se instala."; exit 1; }
echo "✅ Firma correcta. Se abre el instalador: síguelo (pedirá tu contraseña)."
open -W "$PKG"
echo
echo "Activando el driver..."
/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager activate || true
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
echo
echo "Ahora en Ajustes del Sistema → General → Ítems de inicio y extensiones → Extensiones de controlador (ⓘ)"
echo "activa 'Karabiner-VirtualHIDDevice'. Después ejecuta 'Install service'."
read -k 1 "?Pulsa una tecla para cerrar..."
