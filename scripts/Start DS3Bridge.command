#!/bin/zsh
# Arranca DS3Bridge. Cuando ponga "Esperando", pulsa PS en el mando.
# Para pararlo: cierra esta ventana o pulsa Ctrl+C.
# IMPORTANTE: para el programa ANTES de desenchufar el adaptador Bluetooth USB.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -f "bin/ds3host" 2>/dev/null
if [ ! -x "$ROOT/bin/ds3host" ]; then echo "Primero compila con ./build.sh"; read -k 1; exit 1; fi
if [ -S /var/run/ds3bridge.sock ]; then
  echo "Modo teclado: teclado virtual HID (Karabiner)."
else
  echo "Aviso: el servicio de teclado virtual no está instalado; se usarán teclas sintéticas"
  echo "(valen para la mayoría de apps, pero no para jugar en OpenEmu)."
fi
echo
cd "$ROOT/bin" && exec ./ds3host
