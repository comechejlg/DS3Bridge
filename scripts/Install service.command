#!/bin/zsh
# Instala el teclado virtual de DS3Bridge como servicio del sistema (arranca solo con el Mac)
# y crea DS3Bridge.app en Aplicaciones. Pide la contraseña UNA vez.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ME_UID=$(id -u)
DAEMON='/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon'
[ -x "$ROOT/bin/vhidkbd" ] || { echo "Primero compila con ./build.sh"; exit 1; }
[ -x "$DAEMON" ] || { echo "Primero instala el driver con 'Install Karabiner driver'"; exit 1; }
echo "Instalando el servicio de DS3Bridge (se pedirá tu contraseña)..."
sudo -v

# El binario va a una carpeta solo-root: un servicio root no debe ejecutar ficheros editables por el usuario.
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

# El socket queda con dueño = tu usuario y permisos 0600: solo tú puedes mandar teclas al teclado virtual.
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

# App en Aplicaciones que abre el lanzador
rm -rf /Applications/DS3Bridge.app
osacompile -o /Applications/DS3Bridge.app \
  -e "do shell script \"open -a Terminal \" & quoted form of \"$ROOT/scripts/Start DS3Bridge.command\""

sleep 3
if [ -S /var/run/ds3bridge.sock ]; then
  echo; echo "✅ Instalado. Abre DS3Bridge desde Aplicaciones: ya no pedirá contraseña."
else
  echo; echo "⚠️  El servicio aún no ha creado su socket. Mira /var/log/ds3bridge-vhidkbd.log"
fi
read -k 1 "?Pulsa una tecla para cerrar..."
