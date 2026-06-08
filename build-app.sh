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
cp Fonts/KonamiClassic.otf "$APP/Contents/Resources/"
[ -f Fonts/OFL.txt ] && cp Fonts/OFL.txt "$APP/Contents/Resources/"

# Shazam (ShazamKit catalog matching) is authorized like it is on iOS: ShazamKit is an App
# *Service* enabled on the App ID — NOT a profile capability — so the bundle just has to be
# signed claiming that App ID identity, with a provisioning profile (tied to the same App ID)
# embedded to vouch for it. There is no "shazamkit" entitlement. To enable Shazam:
#   1. In the developer portal, enable the "ShazamKit" App Service on App ID
#      com.themarco.timebox-nowplaying.
#   2. Create a Developer ID provisioning profile for that App ID and save it here as
#      TimeboxNowPlaying.provisionprofile.
# This needs a real Developer ID identity: the App-ID-claiming entitlements must be vouched
# for by the embedded profile, which an ad-hoc signature can't do. So we only embed the
# profile + apply entitlements when BOTH the identity and the profile are present. Without
# them the build still works; the System now-playing source + clock are unaffected, only
# Shazam reports "Missing entitlements" at runtime.
PROFILE="TimeboxNowPlaying.provisionprofile"
SIGN_ARGS=()

# Code-sign with a stable Developer ID identity so the TCC (Bluetooth/Microphone) grants
# persist across rebuilds. Ad-hoc signatures are tied to the binary hash, so they change
# every build and macOS re-prompts for permission each time. Falls back to ad-hoc if no
# Developer ID cert is in the keychain.
IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    if [ -f "$PROFILE" ]; then
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        SIGN_ARGS+=(--entitlements "TimeboxNowPlaying.entitlements")
        echo "Embedding provisioning profile — Shazam (App ID service) authorized."
    else
        echo "note: no $PROFILE — Shazam will report \"Missing entitlements\" at runtime."
        echo "      (System now-playing source + clock work without it.)"
    fi
    codesign --force --deep "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" --sign "$IDENTITY" "$APP"
else
    echo "warning: no Developer ID cert found — ad-hoc signing (will re-prompt each build,"
    echo "         and Shazam can't be authorized; System source + clock still work)."
    codesign --force --deep --sign - "$APP"
fi
echo "Signed: $(codesign -dvv "$APP" 2>&1 | grep -E 'Authority=|Identifier=' | tr '\n' ' ')"

echo "Built $APP"
echo "Launch with:  open $APP"
