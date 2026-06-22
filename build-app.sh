#!/usr/bin/env bash
# Build "Claude Usage & Now Playing for Pixoo 64" and wrap the binary in a proper .app bundle so
# it gets a menu-bar presence and stable identity. Usage: ./build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="Claude Usage & Now Playing for Pixoo 64.app"
EXEC="ClaudeUsagePixoo64"                 # must match CFBundleExecutable in the Info.plist
INFO_PLIST="TimeboxNowPlaying-Info.plist"
PROFILE="Pixoo64Claude.provisionprofile"  # Developer ID profile for com.aicreated.pixoo64-claude

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TimeboxNowPlaying" "$APP/Contents/MacOS/$EXEC"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
for f in Fonts/KonamiClassic.otf Fonts/Tiny5-Regular.ttf Fonts/OFL.txt; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done

# Shazam (ShazamKit catalog matching) is an App *Service* on the App ID — authorized only when a
# matching Developer ID provisioning profile is embedded. Without it, the System now-playing
# source + clock + Claude usage all still work; only Shazam reports "missing entitlements".
if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="TimeboxNowPlaying-shazam.entitlements"
    echo "Embedding $PROFILE — Shazam authorized."
else
    ENTITLEMENTS="TimeboxNowPlaying.entitlements"
    echo "note: no $PROFILE — Shazam unauthorized (everything else works)."
fi

# Code-sign with a stable Developer ID identity so TCC (Bluetooth/Microphone/Local-Network) and
# the "Always Allow" Keychain grant for Claude Code's token persist across rebuilds. Ad-hoc
# signatures change every build, so macOS would re-prompt each time. Falls back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
    echo "warning: no Developer ID cert — ad-hoc signing (macOS will re-prompt for permissions each build)."
    codesign --force --deep --sign - "$APP"
fi
echo "Signed: $(codesign -dvv "$APP" 2>&1 | grep -E 'Authority=|Identifier=' | tr '\n' ' ')"

echo "Built $APP"
echo "Launch with:  open \"$APP\""
