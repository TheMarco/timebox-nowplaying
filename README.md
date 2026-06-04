# Timebox Now Playing

A tiny macOS menu-bar app that mirrors your Mac's **now-playing album art** and a
**clock** onto a [Divoom **Timebox Evo**](https://www.divoom.com/) (16×16 LED display) over
Bluetooth — no Divoom app required. It can pull the art from whatever your Mac is playing,
or identify whatever's playing in the room with **Shazam**.

It's a thin consumer of the [`timebox-studio`](https://github.com/TheMarco/timebox-studio)
library, which does the protocol + Bluetooth work.

## Download

**[⬇️ Download the latest release](https://github.com/TheMarco/timebox-nowplaying/releases/latest)**

Grab the `.dmg`, open it, and drag **Timebox Now Playing** into Applications. The build is
signed and notarized by Apple, so it opens with a normal double-click.

> The app lives in the **menu bar** (the `display` icon), not the Dock — there's no window.

## Requirements

- macOS 13 (Ventura) or later. **Shazam needs macOS 14 (Sonoma) or later.**
- A Divoom Timebox Evo, **paired** in System Settings → Bluetooth.

## First launch

Click the menu-bar icon → **Connect to Timebox**, then pick what to show. macOS will ask for
a few permissions the first time, depending on what you use:

- **Bluetooth** — required, to talk to the Timebox.
- **Microphone** — only if you pick the **Shazam** source (it listens to identify songs).
- **Automation (“control Music”)** — only as a fallback, to read album art from the Music app.

If the Timebox doesn't appear, make sure it's paired in Bluetooth settings; if a connection
hangs, power-cycle the Timebox (macOS sometimes grabs its serial channel for audio).

## What it shows

- **Source** — *Now Playing (System)* mirrors whatever your Mac reports playing (any app);
  *Shazam (listen)* identifies ambient music via the microphone.
- **Album art** — the current cover, rendered down to 16×16 (falls back to an iTunes Search
  lookup when a track has no embedded artwork, e.g. streaming).
- **Clock** — analog, or a digital clock that scrolls the “Artist — Title” ticker. Off, too.
- **Album-art dwell** — how long the cover stays up before cycling to the clock.

## Build from source

```sh
./build-app.sh           # builds + bundles + signs TimeboxNowPlaying.app for local use
open TimeboxNowPlaying.app
```

This expects the [`timebox-studio`](https://github.com/TheMarco/timebox-studio) library
checked out next to this repo (a local SwiftPM path dependency, `../TimeBox`).

### Shazam authorization (maintainer)

Shazam's catalog matching is a ShazamKit **App Service**, enabled on the App ID — not a
profile entitlement. To build a copy where Shazam works, you need the App Service enabled on
the App ID and a **Developer ID provisioning profile** for it saved as
`TimeboxNowPlaying.provisionprofile` (git-ignored). Without it the build still works; only
the Shazam source is unavailable. See the header of `build-app.sh` for the exact steps.

### Cutting a release (maintainer)

`./release.sh` builds the release config, signs it with the hardened runtime, notarizes it
with Apple, and produces `TimeboxNowPlaying-<version>.dmg`. It needs a one-time
`notarytool store-credentials` setup (the script prints the exact command if it's missing).
Then publish the DMG as a GitHub Release — the Download link above always points to the
newest one.

## Disclaimer

This is an unofficial, community-built app and is **not affiliated with or endorsed by
Divoom**. “Timebox” and “Divoom” are trademarks of their respective owner.
