# Claude Usage & Now Playing for Pixoo 64

A tiny macOS menu-bar app that drives a Divoom **Pixoo 64** (64×64 LED panel, over Wi-Fi) —
or the original **Timebox Evo** (16×16, over Bluetooth) — with two things at once, cycling
between them:

- **Claude Code usage** — a warm pixel-art gizmo starring *clawd*, the Claude mascot, showing
  your 5-hour **session** window, your **weekly** window, and a **7-day token graph**.
- **Now playing** — your Mac's current **album art** plus a **clock** (analog, or a digital
  clock that scrolls the “Artist — Title” ticker over a cover-tinted background). Art comes
  from whatever your Mac is playing, or from **Shazam** listening to the room.

It runs from the **menu bar** (the line-chart icon), not the Dock — there's no window. On
launch it finds a Pixoo 64 on your network by itself and just starts showing things; no Divoom
app required.

> This project began as a 16×16 Timebox app (hence the old `timebox-nowplaying` name) and grew
> Pixoo 64 support and the Claude usage gizmo. Both devices are still supported.

## Download

**[⬇️ Download the latest release](https://github.com/TheMarco/divoom-pixoo64-timebox-tools/releases/latest)**

Grab the `.dmg`, open it, and drag the app into Applications. The build is signed and notarized
by Apple, so it opens with a normal double-click.

## Requirements

- macOS 13 (Ventura) or later. **Shazam needs macOS 14 (Sonoma) or later.**
- A **Divoom Pixoo 64** on the same Wi-Fi, **or** a **Divoom Timebox Evo** paired in
  System Settings → Bluetooth. (You can drive either, or both at different times.)

## First launch

The app auto-connects to a Pixoo 64 it finds on your network. If you have a different setup,
click the menu-bar icon → **Connect** and pick:

- **Pixoo 64 — find on network** — discovers it via Divoom's same-LAN lookup, then an active
  subnet scan; retries on its own until it appears.
- **Pixoo 64 — enter IP address…** — type the IP (shown in the Divoom app); it's remembered.
- **Timebox (Bluetooth)** — connects to the first paired Timebox Evo.

macOS asks for a few permissions the first time, depending on what you use:

- **Local Network** — to find and talk to the Pixoo 64 over Wi-Fi.
- **Bluetooth** — only for the Timebox path.
- **Microphone** — only if you pick the **Shazam** source (it listens to identify songs).
- **Automation (“control Music”)** — only as a fallback, to read album art from the Music app.

If a Pixoo doesn't appear, make sure it's on this Wi-Fi. If a Timebox connection hangs,
power-cycle it (macOS sometimes grabs its serial channel for audio).

## What it shows

Everything below is toggled from the menu, and all the enabled screens **interleave** in one
cycle:

- **Claude usage (clawd)** — three screens that rotate: *session* (5-hour window: % used, a
  bar, reset countdown), *weekly* (same, for the weekly window), and a *graph* of the last
  7 days of token usage. Token totals are read straight from your local Claude Code logs
  (`~/.claude/projects/**/*.jsonl`); the plan percentages and reset times come from Anthropic's
  OAuth usage endpoint (the same data behind `/usage`), using Claude Code's own stored token.
- **Album art** — the current cover, rendered to the panel's resolution (falls back to an
  iTunes Search lookup when a track has no embedded artwork, e.g. streaming).
- **Display Style** — an optional lo-fi pixel-art restyle of the cover: adaptive palettes
  (*Soft / Classic / Crunchy*), console palettes (*Game Boy, PICO-8, C64, NES, ZX Spectrum,
  CGA, Vaporwave, 1-bit*), and monochrome/CRT ramps (*Mono, Sepia, Green CRT, Amber CRT,
  Virtual Boy, Thermal*). Off by default.
- **Clock** — *Analog*, *Digital* (scrolls the “Artist — Title” ticker over a cover-tinted hero
  background), or *Off*.
- **Now-playing source** — *System (any player)* mirrors whatever your Mac reports playing;
  *Shazam (listen)* identifies ambient music via the microphone.
- **Screen dwell** — how long each screen stays up before cycling (5–60s). The digital clock's
  dwell is dynamic: it ends once the title has finished scrolling past.

There's also an **Open simulator window** item that renders the whole loop to an on-screen
64×64 panel, so you can see everything without a device.

## How it drives each device

- **Pixoo 64** is driven over its **Wi-Fi HTTP JSON API** (`POST http://<ip>/post`). Because the
  HTTP round-trips cap frame streaming at a few fps, each screen is driven through the device's
  own engine: a static frame faded in through black, native scrolling text for the ticker, and
  only live content refreshed.
- **Timebox Evo** is driven over **Bluetooth Classic**, streaming every 16×16 frame and
  crossfading between screens. The Bluetooth work lives in the companion
  [`timebox-studio`](https://github.com/TheMarco/timebox-studio) library (a local SwiftPM path
  dependency, `../TimeBox`).

A single render loop serves both panels; per-device timing and geometry come from a small
`DisplayProfile`.

## Build from source

```sh
./build-app.sh           # builds + bundles + signs the .app for local use
open "Claude Usage & Now Playing for Pixoo 64.app"
```

This expects the [`timebox-studio`](https://github.com/TheMarco/timebox-studio) library checked
out next to this repo (the `../TimeBox` SwiftPM path dependency).

### Shazam authorization (maintainer)

Shazam's catalog matching is a ShazamKit **App Service**, enabled on the App ID — not a profile
entitlement. To build a copy where Shazam works, you need the App Service enabled on the App ID
and a **Developer ID provisioning profile** for it saved as `Pixoo64Claude.provisionprofile`.
Without it the build still works; only the Shazam source is unavailable (the System source,
clock, and Claude usage are unaffected).

### Cutting a release (maintainer)

`./release.sh` builds the release config, signs it with the hardened runtime, notarizes it with
Apple, and produces `ClaudeUsageNowPlayingPixoo64-<version>.dmg`. It needs a one-time
`notarytool store-credentials` setup (the script prints the exact command if it's missing). Then
publish the DMG as a GitHub Release — the Download link above always points to the newest one.

## Provenance & attribution

**This project is original work and is not based on anyone's existing code.**

- The **Pixoo 64** support is built from **Divoom's publicly available documentation of their
  REST API** for the Pixoo 64 — the documented HTTP JSON commands (`Draw/SendHttpGif`,
  `Draw/SendHttpText`, `Channel/SetBrightness`, and so on).
- The **Timebox Evo** support was built by **studying the device's Bluetooth communication
  protocol directly** and mimicking the behavior observed on the wire. Divoom does not publish a
  protocol spec for it; this is a clean-room re-implementation of the observed messages.

No code from Divoom's apps, or from any third-party library, was copied or adapted to create
either path.

## Disclaimer

This is an unofficial, community-built app and is **not affiliated with or endorsed by Divoom**.
“Pixoo”, “Timebox”, and “Divoom” are trademarks of their respective owner. “Claude” and “Claude
Code” are trademarks of Anthropic; this app is an independent tool and is not affiliated with or
endorsed by Anthropic.
