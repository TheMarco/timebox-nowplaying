#!/usr/bin/env bash
# Build a distributable, **notarized** TimeboxNowPlaying.app and package it as a DMG that
# opens with a normal double-click on other people's Macs (no Gatekeeper warning).
#
# Unlike build-app.sh (fast local debug loop), this:
#   - builds release config,
#   - signs with the **hardened runtime** + a secure timestamp + the full entitlements
#     (App-ID identity for ShazamKit, plus mic + Apple-Events for the hardened runtime),
#   - submits to Apple's notary service and staples the ticket,
#   - produces TimeboxNowPlaying-<version>.dmg.
#
# One-time setup (stores an app-specific password in your keychain under a named profile):
#   xcrun notarytool store-credentials "timebox-notary" \
#       --apple-id "<your-apple-id-email>" \
#       --team-id 3ML6V62AF5 \
#       --password "<app-specific-password from appleid.apple.com -> App-Specific Passwords>"
#
# Usage: ./release.sh        (override the profile name with NOTARY_PROFILE=... ./release.sh)
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-timebox-notary}"
APP="TimeboxNowPlaying.app"
PROFILE_FILE="TimeboxNowPlaying.provisionprofile"
ENTITLEMENTS="TimeboxNowPlaying.entitlements"
INFO_PLIST="TimeboxNowPlaying-Info.plist"
TEAM_ID="3ML6V62AF5"

# ---- preflight -------------------------------------------------------------------------
IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "error: no \"Developer ID Application\" certificate in the keychain."; exit 1; }

[ -f "$PROFILE_FILE" ] || { echo "error: $PROFILE_FILE is missing — Shazam won't be authorized in the distributed app. See build-app.sh header."; exit 1; }

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat <<EOF
error: no notarytool credentials stored under profile "$NOTARY_PROFILE".

Run this once, then re-run ./release.sh:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your-apple-id-email>" \\
      --team-id $TEAM_ID \\
      --password "<app-specific-password>"

Create the app-specific password at https://appleid.apple.com -> Sign-In & Security ->
App-Specific Passwords. (Override the profile name with NOTARY_PROFILE=... ./release.sh)
EOF
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG="TimeboxNowPlaying-$VERSION.dmg"

# ---- build (release) -------------------------------------------------------------------
echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# ---- assemble the .app bundle (mirrors build-app.sh) -----------------------------------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TimeboxNowPlaying" "$APP/Contents/MacOS/TimeboxNowPlaying"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp Fonts/Tiny5-Regular.ttf "$APP/Contents/Resources/"
[ -f Fonts/OFL.txt ] && cp Fonts/OFL.txt "$APP/Contents/Resources/"
cp "$PROFILE_FILE" "$APP/Contents/embedded.provisionprofile"

# ---- sign with the hardened runtime ----------------------------------------------------
echo "==> codesign (hardened runtime + timestamp)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ---- package as a DMG (app + drag-to-Applications shortcut) ----------------------------
echo "==> building $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Timebox Now Playing" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# ---- notarize + staple -----------------------------------------------------------------
echo "==> submitting to the Apple notary service (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> stapling"
xcrun stapler staple "$DMG"

# ---- verify ----------------------------------------------------------------------------
echo "==> verifying"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true

echo
echo "Done: $DMG"
echo "Publish it as a GitHub Release asset (the README's Download link points to /releases/latest):"
echo "  gh release create v$VERSION \"$DMG\" --title \"v$VERSION\" --notes \"…\""
