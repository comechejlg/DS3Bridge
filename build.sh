#!/bin/zsh
# DS3Bridge — downloads the dependencies (pinned versions), applies the patches and builds.
# Usage:  ./build.sh          build everything into ./bin
#         ./build.sh --clean  delete build/ and bin/
set -e
cd "$(dirname "$0")"
ROOT="$PWD"

# Tested versions (do not change without testing again)
BTSTACK_URL=https://github.com/bluekitchen/btstack.git
BTSTACK_COMMIT=e38553977a25fb0b55b383c72c289be0975f422c
KARABINER_URL=https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git
KARABINER_COMMIT=ac836ed8a974cd5182495251855cabdb762f50cb

if [[ "$1" == "--clean" ]]; then
  rm -rf build bin
  echo "Clean."
  exit 0
fi

# Requirements
if ! command -v clang >/dev/null; then
  echo "Xcode Command Line Tools are missing. Install them with:  xcode-select --install"; exit 1
fi
if ! command -v pkg-config >/dev/null || ! pkg-config --exists libusb-1.0; then
  echo "libusb is missing. Install it with Homebrew:  brew install libusb pkg-config"; exit 1
fi

fetch() {  # name url commit
  if [ ! -d "deps/$1/.git" ]; then
    echo "Downloading $1..."
    git clone -q --filter=blob:none "$2" "deps/$1"
  fi
  git -C "deps/$1" fetch -q origin "$3" 2>/dev/null || true
  git -C "deps/$1" -c advice.detachedHead=false checkout -q "$3"
}
mkdir -p deps build bin
fetch btstack "$BTSTACK_URL" "$BTSTACK_COMMIT"
fetch karabiner-vhid "$KARABINER_URL" "$KARABINER_COMMIT"

# 1) ds3host: own Bluetooth host (BTstack + patches) + DSU + keyboard
echo "Building ds3host..."
mkdir -p build/ds3host
cp src/ds3host/* build/ds3host/
cp deps/btstack/port/libusb/main.c build/ds3host/
cp deps/btstack/platform/libusb/hci_transport_h2_libusb.c build/ds3host/
( cd build/ds3host
  patch -s main.c < "$ROOT/patches/btstack/main.c.patch"
  patch -s hci_transport_h2_libusb.c < "$ROOT/patches/btstack/hci_transport_h2_libusb.c.patch" )
make -s -C build/ds3host BTSTACK_ROOT="$ROOT/deps/btstack" 2>&1 | grep -E "error|Error" || true
cp build/ds3host/ds3host bin/

# 2) vhidkbd: bridge to the Karabiner virtual HID keyboard (runs as root)
echo "Building vhidkbd..."
clang++ -std=c++23 -O2 \
  -isystem deps/karabiner-vhid/vendor/vendor/include -isystem deps/karabiner-vhid/include \
  src/vhidkbd/vhidkbd.cpp -o bin/vhidkbd -framework CoreFoundation -framework IOKit

# 3) ds3bt: cable pairing (writes the adapter's address into the controller)
echo "Building ds3bt..."
clang -O2 -fobjc-arc -Wall src/ds3bt/ds3bt.m -o bin/ds3bt \
  -framework Foundation -framework IOKit -framework CoreFoundation -framework IOBluetooth

echo
echo "✅ Done: $(ls bin | tr '\n' ' ')"
