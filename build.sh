#!/bin/zsh
# DS3Bridge — downloads the dependencies (pinned versions), applies the patches and builds.
# Usage:  ./build.sh            build everything into ./bin
#         ./build.sh --release  same, with libusb built in, and package dist/DS3Bridge-macOS-arm64.dmg
#         ./build.sh --clean    delete build/, bin/ and dist/
set -e
cd "$(dirname "$0")"
ROOT="$PWD"

# Tested versions (do not change without testing again)
BTSTACK_URL=https://github.com/bluekitchen/btstack.git
BTSTACK_COMMIT=e38553977a25fb0b55b383c72c289be0975f422c
KARABINER_URL=https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice.git
KARABINER_COMMIT=ac836ed8a974cd5182495251855cabdb762f50cb
# Realtek Bluetooth firmware (for RTL8761B dongles such as the TP-Link UB500), from linux-firmware
LINUX_FIRMWARE_URL=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
LINUX_FIRMWARE_COMMIT=73e8acec66b0a91513e0699567b7854f4161d8b5

VERSION=1.1.0
RELEASE=0
[[ "$1" == "--release" ]] && RELEASE=1

if [[ "$1" == "--clean" ]]; then
  rm -rf build bin dist firmware
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

# Realtek firmware: ds3host loads it into Realtek dongles at startup (they don't accept
# connections without it). Saved under the names BTstack looks for, and checked by SHA-256.
fw() {  # linux-firmware path, file name for BTstack, sha256
  if [ -f "firmware/$2" ] && [ "$(shasum -a 256 "firmware/$2" | cut -d' ' -f1)" = "$3" ]; then return; fi
  echo "Downloading $1..."
  curl -fsSL -o "firmware/$2.tmp" "$LINUX_FIRMWARE_URL/$1?id=$LINUX_FIRMWARE_COMMIT"
  if [ "$(shasum -a 256 "firmware/$2.tmp" | cut -d' ' -f1)" != "$3" ]; then
    rm -f "firmware/$2.tmp"; echo "❌ Unexpected checksum for $1"; exit 1
  fi
  mv "firmware/$2.tmp" "firmware/$2"
}
mkdir -p firmware
fw rtl_bt/rtl8761bu_fw.bin     rtl8761bu_fw     1d7a9597349ad89344fa16c1913d3e39e9a12e966e417ca16871bc79bbe59edb
fw rtl_bt/rtl8761bu_config.bin rtl8761bu_config 6c28a3f07c6a30ed208c4b64862a23f02b7d93543ea980edd24df16bab45095f
fw LICENSES/LICENCE.rtlwifi_firmware.txt LICENCE.rtlwifi_firmware.txt a61351665b4f264f6c631364f85b907d8f8f41f8b369533ef4021765f9f3b62e

# 1) ds3host: own Bluetooth host (BTstack + patches) + DSU + keyboard
echo "Building ds3host..."
mkdir -p build/ds3host
cp src/ds3host/* build/ds3host/
cp deps/btstack/port/libusb/main.c build/ds3host/
cp deps/btstack/platform/libusb/hci_transport_h2_libusb.c build/ds3host/
( cd build/ds3host
  patch -s main.c < "$ROOT/patches/btstack/main.c.patch"
  patch -s hci_transport_h2_libusb.c < "$ROOT/patches/btstack/hci_transport_h2_libusb.c.patch" )
rm -f build/ds3host/ds3host
make -s -C build/ds3host BTSTACK_ROOT="$ROOT/deps/btstack" STATIC_LIBUSB=$RELEASE 2>&1 | grep -E "error|Error" || true
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

# 4) Release package: DS3Bridge.app with everything inside, in a disk image (GitHub Releases)
if [[ $RELEASE == 1 ]]; then
  if otool -L bin/* | grep -q -E '/opt/homebrew|/usr/local/(opt|Cellar)'; then
    echo "❌ A binary still links a Homebrew library:"; otool -L bin/*; exit 1
  fi
  NAME=DS3Bridge-macOS-arm64
  APP=dist/DS3Bridge.app
  RES="$APP/Contents/Resources/DS3Bridge"
  rm -rf dist && mkdir -p dist
  echo "Building DS3Bridge.app..."
  osacompile -o "$APP" assets/app/main.applescript
  cp assets/DS3Bridge.icns "$APP/Contents/Resources/applet.icns"
  # Recent macOS prefers the applet's asset catalog (CFBundleIconName) over applet.icns.
  rm -f "$APP/Contents/Resources/Assets.car"
  plutil -remove CFBundleIconName "$APP/Contents/Info.plist" 2>/dev/null || true
  mkdir -p "$RES/licenses"
  cp -R bin scripts docs firmware README.md README.es.md LICENSE THIRD_PARTY_NOTICES.md "$RES/"
  cp licenses/* "$RES/licenses/"
  cp deps/btstack/LICENSE "$RES/licenses/BTstack.txt"
  cp "$(pkg-config libusb-1.0 --variable=prefix)/COPYING" "$RES/licenses/libusb-LGPL-2.1.txt"
  cp deps/karabiner-vhid/LICENSE.md "$RES/licenses/Karabiner-DriverKit-VirtualHIDDevice.md"
  PL="$APP/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string io.github.comechejlg.ds3bridge "$PL"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$PL"
  plutil -replace CFBundleVersion -string "$VERSION" "$PL"
  plutil -replace NSHumanReadableCopyright -string "MIT License. Third-party licenses in Contents/Resources/DS3Bridge/licenses." "$PL"
  xattr -cr "$APP"
  codesign --force --deep --sign - "$APP"   # ad-hoc: the app is not notarized (no Apple Developer ID)

  # Disk image with a custom window (background, icon positions, link to Applications).
  # dmgbuild writes the window layout directly, so Finder scripting is not needed.
  echo "Building $NAME.dmg..."
  if ! build/venv/bin/python3 -c "import dmgbuild" 2>/dev/null; then
    rm -rf build/venv
    python3 -m venv build/venv
    build/venv/bin/pip install -q "dmgbuild>=1.6,<2"
  fi
  tiffutil -cathidpicheck assets/dmg-background.png assets/dmg-background@2x.png -out build/dmg-background.tiff 2>/dev/null
  build/venv/bin/dmgbuild -s assets/dmg-settings.py \
    -D app="$APP" -D background=build/dmg-background.tiff -D icon=assets/DS3Bridge.icns \
    "DS3Bridge" "dist/$NAME.dmg" >/dev/null
  echo "📦 dist/$NAME.dmg ($(du -h dist/$NAME.dmg | cut -f1))"
fi
