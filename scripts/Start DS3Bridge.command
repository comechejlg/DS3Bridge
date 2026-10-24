#!/bin/zsh
# Starts DS3Bridge. When it says "Waiting", press PS on the controller.
# To stop it: close this window or press Ctrl+C.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -f "bin/ds3host" 2>/dev/null
if [ ! -x "$ROOT/bin/ds3host" ]; then echo "Build first with ./build.sh"; read -k 1; exit 1; fi
if [ -S /var/run/ds3bridge.sock ]; then
  echo "Keyboard mode: virtual HID keyboard (Karabiner)."
else
  echo "Note: the virtual keyboard service is not installed; synthetic keys will be used"
  echo "(fine for most apps, but not for OpenEmu gameplay)."
fi
echo
cd "$ROOT/bin" && exec ./ds3host
