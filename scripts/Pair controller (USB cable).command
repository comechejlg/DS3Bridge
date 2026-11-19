#!/bin/zsh
# Writes the USB adapter's Bluetooth address into the DualShock 3, so it connects
# to it when you press PS. Needed once (and again if you use the controller with
# a PS3 or another device). Connect the controller by USB cable before opening this.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDR_FILE="$HOME/Library/Application Support/DS3Bridge/adapter-address"
if [ ! -f "$ADDR_FILE" ]; then
  echo "The adapter address is not known yet."
  echo "Start DS3Bridge once with the adapter plugged in (it saves the address), close it and pair again."
  read -k 1 "?Press any key to close..."; exit 1
fi
ADDR="$(head -1 "$ADDR_FILE")"
echo "Adapter address: $ADDR"
if "$ROOT/bin/ds3bt" pair "$ADDR"; then
  # Remember which adapter the controller points to, so DS3Bridge can warn after an adapter change.
  echo "$ADDR" > "$HOME/Library/Application Support/DS3Bridge/paired-address"
fi
echo
echo "If it says OK: unplug the cable, start DS3Bridge and press PS."
read -k 1 "?Press any key to close..."
