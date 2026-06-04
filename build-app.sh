#!/usr/bin/env bash
# Build TimeboxNowPlaying and wrap the binary in a proper .app bundle so it gets
# a menu-bar presence and Bluetooth permission handling. Usage: ./build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="TimeboxNowPlaying.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TimeboxNowPlaying" "$APP/Contents/MacOS/TimeboxNowPlaying"
cp "TimeboxNowPlaying-Info.plist" "$APP/Contents/Info.plist"

mkdir -p "$APP/Contents/Resources"
cp Fonts/Tiny5-Regular.ttf "$APP/Contents/Resources/"
[ -f Fonts/OFL.txt ] && cp Fonts/OFL.txt "$APP/Contents/Resources/"

# Ad-hoc code-sign so macOS gives the app a stable identity for TCC (Bluetooth
# permission). Without a signature it never prompts and never appears in the
# Privacy list.
codesign --force --deep --sign - "$APP"
echo "Signed (ad-hoc): $(codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Signature' | tr '\n' ' ')"

echo "Built $APP"
echo "Launch with:  open $APP"
