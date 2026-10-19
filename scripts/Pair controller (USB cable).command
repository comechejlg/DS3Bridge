#!/bin/zsh
# Graba en el DualShock 3 la dirección Bluetooth del adaptador USB, para que se
# conecte a él al pulsar PS. Hace falta una vez (y otra vez si usas el mando en
# una PS3 u otro aparato). Conecta el mando por cable USB antes de abrir esto.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDR_FILE="$HOME/Library/Application Support/DS3Bridge/adapter-address"
if [ ! -f "$ADDR_FILE" ]; then
  echo "Aún no conozco la dirección de tu adaptador."
  echo "Abre 'Start DS3Bridge' una vez con el adaptador enchufado (guarda la dirección), ciérralo y vuelve a abrir este script."
  read -k 1 "?Pulsa una tecla para cerrar..."; exit 1
fi
ADDR="$(head -1 "$ADDR_FILE")"
echo "Dirección del adaptador: $ADDR"
"$ROOT/bin/ds3bt" pair "$ADDR"
echo
echo "Si pone OK: desconecta el cable, abre 'Start DS3Bridge' y pulsa PS."
read -k 1 "?Pulsa una tecla para cerrar..."
