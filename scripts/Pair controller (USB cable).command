#!/bin/zsh
# Writes the USB adapter's Bluetooth address into the DualShock 3, so it connects
# to it when you press PS. Needed once (and again if you use the controller with
# a PS3 or another device). Connect the controller by USB cable before opening this.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDR_FILE="$HOME/Library/Application Support/DS3Bridge/adapter-address"
if [ ! -f "$ADDR_FILE" ]; then
  echo "The adapter address is not known yet."
  echo "Open 'Start DS3Bridge' once with the adapter plugged in (it saves the address), close it and open this script again."
  read -k 1 "?Press any key to close..."; exit 1
fi
ADDR="$(head -1 "$ADDR_FILE")"
echo "Adapter address: $ADDR"
"$ROOT/bin/ds3bt" pair "$ADDR"
echo
echo "If it says OK: unplug the cable, open 'Start DS3Bridge' and press PS."
read -k 1 "?Press any key to close..."
