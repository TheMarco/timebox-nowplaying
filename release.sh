#!/usr/bin/env bash
# Build a distributable, **notarized** "Claude Usage & Now Playing for Pixoo 64.app" and package
# it as a DMG that opens with a normal double-click on other people's Macs (no Gatekeeper warning).
#
# This:
#   - builds release config,
#   - signs with the **hardened runtime** + a secure timestamp + entitlements (mic for the
#     optional Shazam source, Apple-Events for Music artwork),
#   - submits to Apple's notary service and staples the ticket,
#   - produces ClaudeUsageNowPlayingPixoo64-<version>.dmg.
#
# One-time setup — store your app-specific password in your keychain under a named profile:
#   xcrun notarytool store-credentials "pixoo-notary" \
#       --apple-id "<your-apple-id-email>" \
#       --team-id 3ML6V62AF5 \
#       --password "<app-specific-password from appleid.apple.com -> App-Specific Passwords>"
#
# Usage: ./release.sh        (override the profile with NOTARY_PROFILE=... ./release.sh)
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-pixoo-notary}"
APP="Claude Usage & Now Playing for Pixoo 64.app"
EXEC="ClaudeUsagePixoo64"
INFO_PLIST="TimeboxNowPlaying-Info.plist"
PROFILE="Pixoo64Claude.provisionprofile"   # Developer ID profile for com.aicreated.pixoo64-claude
TEAM_ID="3ML6V62AF5"

# ---- preflight -------------------------------------------------------------------------
IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "error: no \"Developer ID Application\" certificate in the keychain."; exit 1; }

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat <<EOF
error: no notarytool credentials stored under profile "$NOTARY_PROFILE".

Run this once, then re-run ./release.sh:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your-apple-id-email>" \\
      --team-id $TEAM_ID \\
      --password "<app-specific-password>"

(Override the profile name with NOTARY_PROFILE=... ./release.sh)
EOF
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG="ClaudeUsageNowPlayingPixoo64-$VERSION.dmg"

# ---- build (release) -------------------------------------------------------------------
echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# ---- assemble the .app bundle ----------------------------------------------------------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TimeboxNowPlaying" "$APP/Contents/MacOS/$EXEC"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
for f in Fonts/KonamiClassic.otf Fonts/Tiny5-Regular.ttf Fonts/OFL.txt; do
    [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"
done

# Shazam needs a Developer ID provisioning profile for the App ID (ShazamKit App Service). When
# present, embed it + claim the App-ID entitlements; otherwise ship without Shazam.
if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS="TimeboxNowPlaying-shazam.entitlements"
    echo "==> embedding $PROFILE — Shazam authorized"
else
    ENTITLEMENTS="TimeboxNowPlaying.entitlements"
    echo "==> no $PROFILE — building without Shazam (System source + clock + Claude usage still work)"
fi

# ---- sign with the hardened runtime ----------------------------------------------------
echo "==> codesign (hardened runtime + timestamp)"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ---- package as a DMG (app + drag-to-Applications shortcut) ----------------------------
echo "==> building $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Claude Usage for Pixoo 64" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
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
