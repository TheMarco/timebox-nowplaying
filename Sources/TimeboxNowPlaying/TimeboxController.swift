import Foundation
import CoreGraphics
import AVFoundation
import TimeboxBluetooth
import TimeboxKit

/// Drives whichever display is connected — a 16×16 Timebox Evo over Bluetooth or a 64×64
/// Divoom Pixoo 64 over WiFi — cycling the now-playing album art and one clock (analog or
/// digital), crossfading between them. The digital clock pins a 12-hour time and scrolls
/// the "Artist — Title" ticker. Mirrors the iOS "Now Playing" module: same render loop,
/// dynamic ticker dwell, and reconnect-on-drop resilience. Per-device timing/geometry comes
/// from the active backend's `DisplayProfile`, so a single loop serves both panels.
@MainActor
final class TimeboxController: ObservableObject {
    @Published var statusText = "Not connected"
    @Published var isConnected = false
    @Published var nowPlayingText = "—"
    @Published var intervalSeconds = 12        // album-art / analog dwell (seconds)
    @Published var showAlbumArt = true

    enum ClockStyle { case off, analog, digital }
    @Published var clockStyle: ClockStyle = .digital

    /// Where the album art / track name comes from. `system` reads the OS "now playing"
    /// (any player, via MediaRemote); `shazam` listens on the mic and identifies whatever
    /// is in the room. Mirrors the iOS app's source toggle.
    enum ArtSource { case system, shazam }
    @Published var artSource: ArtSource = .system {
        didSet {
            guard running, oldValue != artSource else { return }
            restartSource()
        }
    }

    private enum Target { case albumArt, analog, digital }

    private var backend: DisplayBackend?
    private var profile = DisplayProfile.timebox
    private var renderSize: Int { profile.width }
    /// Album art used as the digital "hero" background — only when the user is showing art.
    private var digitalArt: Surface? { showAlbumArt ? artFrame : nil }

    private var artFrame: Surface?
    private var accentColor: PixelRGB?  // vivid color from the current cover; tints the 64×64 clocks + title
    private var artVersion = 0          // bumps on each new cover, so the loop re-sends it
    private var restartCycle = false    // new song: jump back to the cover before scrolling
    private var lastTrackKey = ""

    // Stored as AnyObject so the property type doesn't force the macOS 14 floor onto the
    // whole class — the concrete `ShazamRecognizer` is gated `@available(macOS 14, *)`.
    private var shazamBox: AnyObject?

    private var loop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var running = false

    // MARK: - Discovery (for the connect menu)

    func timeboxDevices() -> [TimeboxDevice] { TimeboxBackend.discover() }
    func pixooDevices() async -> [PixooDevice] { await PixooBackend.discover() }

    // MARK: - Connection

    /// Connect to the first paired Timebox (16×16, Bluetooth).
    func connectTimebox() {
        guard let device = TimeboxBackend.discover().first else {
            statusText = "No Timebox found — pair it, and allow Bluetooth for this app in System Settings → Privacy → Bluetooth"
            return
        }
        start(backend: TimeboxBackend(device: device), connecting: "Connecting to \(device.name)…")
    }

    /// Connect to a Pixoo 64 at an explicit IP (64×64, WiFi).
    func connectPixoo(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        start(backend: PixooBackend(host: trimmed), connecting: "Connecting to Pixoo \(trimmed)…")
    }

    /// Auto-discover a Pixoo on the LAN (Divoom cloud), then connect to it.
    func connectPixooAuto() {
        statusText = "Searching for a Pixoo on your network…"
        Task {
            let found = await PixooBackend.discover()
            guard let device = found.first else {
                statusText = "No Pixoo found on the network — try \"Enter IP address…\""
                return
            }
            start(backend: PixooBackend(host: device.host),
                  connecting: "Connecting to \(device.name) (\(device.host))…")
        }
    }

    private func start(backend newBackend: DisplayBackend, connecting message: String) {
        disconnect()                       // tear down any existing link first
        backend = newBackend
        profile = newBackend.profile
        statusText = message
        Task {
            do {
                try await newBackend.connect()
                isConnected = true
                statusText = "Connected: \(newBackend.label)"
                startLoops()
            } catch {
                isConnected = false
                backend = nil
                statusText = "Connect failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        running = false
        loop?.cancel(); loop = nil
        stopSource()
        backend?.disconnect()
        backend = nil
        isConnected = false
        artFrame = nil
        statusText = "Not connected"
    }

    // MARK: - Loops

    private func startLoops() {
        guard !running else { return }
        running = true
        startSource()
        // The Pixoo is driven by its own engine (static frames + native scrolling text +
        // brightness fades); the Timebox streams every frame over Bluetooth.
        loop = Task { profile.drivesNatively ? await runNativeLoop() : await runLoop() }
    }

    // MARK: - Art sources

    private func startSource() {
        switch artSource {
        case .system:
            pollTask = Task { await pollNowPlaying() }
        case .shazam:
            startShazam()
        }
    }

    private func stopSource() {
        pollTask?.cancel(); pollTask = nil
        if #available(macOS 14.0, *) { (shazamBox as? ShazamRecognizer)?.stop() }
    }

    /// Tear down the current source and bring up the newly-selected one (keeps the render
    /// loop running — just the art feed swaps). Clears the current cover/track so stale art
    /// from the old source doesn't linger.
    private func restartSource() {
        stopSource()
        artFrame = nil
        accentColor = nil
        nowPlayingText = "—"
        lastTrackKey = ""
        startSource()
    }

    /// Poll the OS "now playing" every few seconds; when the track changes, refresh the
    /// cover (embedded art if present, else an iTunes Search lookup by title+artist).
    private func pollNowPlaying() async {
        while running && !Task.isCancelled {
            let info = await fetchNowPlaying()
            let key = [info.artist, info.title].compactMap { $0 }.joined(separator: "|")
            if !key.isEmpty, key != lastTrackKey {
                lastTrackKey = key
                nowPlayingText = [info.artist, info.title].compactMap { $0 }.joined(separator: " — ")
                if let cg = info.artwork, let frame = makeArt(cg) {
                    setArt(frame)
                } else if let cg = await NowPlaying.iTunesArtwork(title: info.title, artist: info.artist),
                          let frame = makeArt(cg) {
                    setArt(frame)
                }
            } else if key.isEmpty {
                nowPlayingText = "—"
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    // MARK: - Shazam source

    @available(macOS 14.0, *)
    private var shazam: ShazamRecognizer {
        if let existing = shazamBox as? ShazamRecognizer { return existing }
        let recognizer = ShazamRecognizer()
        shazamBox = recognizer
        return recognizer
    }

    private func startShazam() {
        guard #available(macOS 14.0, *) else {
            statusText = "Shazam needs macOS 14 or later"
            return
        }
        // Request mic access up front so the failure mode is a clear status line rather than
        // a silent stream of empty recognitions. SHManagedSession captures the default input.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self, self.running, self.artSource == .shazam else { return }
                guard granted else {
                    self.statusText = "Microphone access denied — enable it in System Settings → Privacy → Microphone"
                    return
                }
                self.wireShazam()
                self.shazam.start()
            }
        }
    }

    @available(macOS 14.0, *)
    private func wireShazam() {
        let recognizer = shazam
        recognizer.onStatus = { [weak self] text in self?.statusText = text }
        recognizer.onSong = { [weak self] song in
            guard let self else { return }
            let key = [song.artist, song.title].compactMap { $0 }.joined(separator: "|")
            guard !key.isEmpty, key != self.lastTrackKey else { return }   // same song still playing
            self.lastTrackKey = key
            self.nowPlayingText = [song.artist, song.title].compactMap { $0 }.joined(separator: " — ")
            guard let url = song.artworkURL else {
                // No artwork URL from Shazam — fall back to an iTunes Search lookup.
                let title = song.title, artist = song.artist
                Task { [weak self] in
                    if let cg = await NowPlaying.iTunesArtwork(title: title, artist: artist),
                       let frame = self?.makeArt(cg) { self?.setArt(frame) }
                }
                return
            }
            Task { [weak self] in
                if let cg = await NowPlaying.artwork(from: url), let frame = self?.makeArt(cg) {
                    self?.setArt(frame)
                }
            }
        }
    }

    private func fetchNowPlaying() async -> NowPlayingInfo {
        await withCheckedContinuation { cont in
            NowPlaying.fetch { info in cont.resume(returning: info) }
        }
    }

    /// Rasterize a cover to the active device's resolution and punch up its colors.
    private func makeArt(_ cg: CGImage) -> Surface? {
        ImageToSurface.surface(from: cg, size: renderSize, interpolation: .high)
            .map { ImageEnhance.punchUp($0) }
    }

    private func setArt(_ frame: Surface) {
        artFrame = frame
        accentColor = Palette.accent(from: frame)   // derive a tint for the clocks + title
        artVersion += 1
        restartCycle = true     // new cover → show it first, then scroll the title
    }

    // MARK: - Render loop (mirrors the iOS engine)

    private func targets() -> [Target] {
        var list: [Target] = []
        if showAlbumArt, artFrame != nil { list.append(.albumArt) }
        switch clockStyle {
        case .analog: list.append(.analog)
        case .digital: list.append(.digital)
        case .off: break
        }
        return list
    }

    private func tickerText() -> String { nowPlayingText == "—" ? "" : nowPlayingText }

    private func render(_ target: Target, scroll: Int) -> Surface {
        switch target {
        case .albumArt: return artFrame ?? ClockRenderer.surface(for: Date(), size: renderSize)
        case .analog: return ClockRenderer.surface(for: Date(), size: renderSize, accent: accentColor)
        case .digital: return DigitalClockRenderer.surface(
            for: Date(), ticker: tickerText(), scroll: scroll,
            size: renderSize, tickerScale: profile.tickerScale, accent: accentColor, art: digitalArt)
        }
    }

    /// How far the ticker must scroll before it's fully off the left edge (device pixels).
    private func tickerSpan(_ text: String) -> Int {
        PixelFont.columns(for: text).count * profile.tickerScale + profile.width
    }

    private func runLoop() async {
        let clock = ContinuousClock()
        var next = clock.now
        var lastFrame: Surface?
        var index = 0
        var elapsed = 0.0
        var scroll = 0
        var lastSecond = -1
        var lastArtVersion = artVersion

        while running && !Task.isCancelled {
            if !isConnected {                        // dropped: try to reconnect, then wait
                statusText = "Reconnecting…"
                lastFrame = nil
                await attemptReconnect()
                if !isConnected { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                next = clock.now
                continue
            }
            let items = targets()
            guard !items.isEmpty else {              // nothing selected: just show the clock
                await sendSafely(ClockRenderer.surface(for: Date(), size: renderSize), last: &lastFrame)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                next = clock.now
                continue
            }
            if restartCycle {
                restartCycle = false
                index = 0; elapsed = 0; scroll = 0   // new song: cover first, then scroll
            }
            if index >= items.count { index = 0; elapsed = 0; scroll = 0 }
            let target = items[index]
            let entering = elapsed == 0
            let frame = render(target, scroll: scroll)

            if entering {
                if let from = lastFrame, from.width == frame.width, from.height == frame.height {
                    for f in Blend.crossfade(from: from, to: frame, steps: profile.crossfadeSteps) {
                        if !running { break }
                        await sendSafely(f, last: &lastFrame)
                        if profile.crossfadeStepDelay > 0 {
                            try? await Task.sleep(nanoseconds: profile.crossfadeStepDelay)
                        }
                    }
                } else {
                    await sendSafely(frame, last: &lastFrame)
                }
                lastSecond = Calendar.current.component(.second, from: Date())
                lastArtVersion = artVersion
            } else {
                // Digital scrolls every tick; analog refreshes per second; art is re-sent
                // only when a new cover arrives.
                var send = false
                switch target {
                case .digital:
                    send = true
                case .analog:
                    let sec = Calendar.current.component(.second, from: Date())
                    if sec != lastSecond { send = true; lastSecond = sec }
                case .albumArt:
                    if artVersion != lastArtVersion { send = true; lastArtVersion = artVersion }
                }
                if send { await sendSafely(frame, last: &lastFrame) }
            }

            // Steady, deadline-based pacing so frame intervals stay even (less stutter).
            // On HTTP, a send that overruns `tick` simply makes the loop run at the
            // achievable rate (the deadline is already past, so no sleep).
            next = next.advanced(by: .seconds(profile.tick))
            if next < clock.now { next = clock.now }
            try? await clock.sleep(until: next, tolerance: .zero)
            elapsed += profile.tick
            if target == .digital { scroll += profile.scrollStep }   // scroll the title in/out

            // The digital clock's dwell is dynamic (ends once the title has scrolled away);
            // the cover and analog clock use the interval.
            let done: Bool
            switch target {
            case .digital:
                let text = tickerText()
                done = !text.isEmpty && scroll >= tickerSpan(text)
            case .albumArt, .analog:
                done = elapsed >= Double(max(2, intervalSeconds))
            }
            if done {
                if items.count > 1 {
                    elapsed = 0; scroll = 0
                    index = (index + 1) % max(1, targets().count)
                } else if target == .digital {
                    elapsed = 0; scroll = 0   // only the clock showing: loop the ticker
                }
            }
        }
    }

    // MARK: - Native render loop (Pixoo)

    private func clockMinute() -> Int { Calendar.current.component(.minute, from: Date()) }

    /// The Pixoo can't stream frames smoothly, so each view fades in through black, then the
    /// loop refreshes only live content. The digital view streams its title scrolling in from
    /// the right exactly once (like the Timebox), then advances to the cover.
    private func runNativeLoop() async {
        guard let pixoo = backend as? PixooBackend else { return }

        while running && !Task.isCancelled {
            if !isConnected {
                statusText = "Reconnecting…"
                await attemptReconnect()
                if !isConnected { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                continue
            }

            let items = targets()
            if items.isEmpty {                       // nothing selected: just show the clock
                try? await pixoo.present(ClockRenderer.surface(for: Date(), size: renderSize), fade: false)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if restartCycle { restartCycle = false }

            var index = 0
            // Re-evaluate the (possibly changed) target list each cycle.
            while running && !Task.isCancelled && isConnected {
                let live = targets()
                if live.isEmpty || restartCycle { break }
                index %= live.count
                let target = live[index]
                let multi = live.count > 1

                switch target {
                case .digital: await presentDigital(on: pixoo, multi: multi)
                case .analog:  await presentAnalog(on: pixoo, multi: multi)
                case .albumArt: await presentCover(on: pixoo, multi: multi)
                }

                if multi { index += 1 }              // single target: re-enter (re-scroll / refresh)
            }
        }
    }

    private var nativeLoopAlive: Bool {
        running && !Task.isCancelled && isConnected && !restartCycle
    }

    /// Digital: fade in, scroll the "Artist — Title" in from the right exactly once, then
    /// return so the loop transitions to the album cover. With no title, hold the clock.
    private func presentDigital(on pixoo: PixooBackend, multi: Bool) async {
        let title = tickerText()
        var scroll = 0
        func frame() -> Surface {
            DigitalClockRenderer.surface(for: Date(), ticker: title, scroll: scroll,
                                         size: renderSize, tickerScale: profile.tickerScale,
                                         accent: accentColor, art: digitalArt)
        }
        try? await pixoo.present(frame(), fade: true)   // enter (title starts off the right edge)

        guard !title.isEmpty else {                     // no song: just show the clock
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(Double(max(4, intervalSeconds))))
            var lastMinute = clockMinute()
            while nativeLoopAlive {
                if clockMinute() != lastMinute { lastMinute = clockMinute(); try? await pixoo.present(frame(), fade: false) }
                if multi && clock.now >= deadline { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }

        let span = tickerSpan(title)
        while nativeLoopAlive {
            scroll += profile.scrollStep
            try? await pixoo.present(frame(), fade: false)
            if scroll >= span {                         // one full pass complete
                if multi { return }                     // → transition to the cover
                scroll = 0                              // only the clock showing: loop the ticker
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Analog: fade in, then refresh ~once a second for the dwell.
    private func presentAnalog(on pixoo: PixooBackend, multi: Bool) async {
        func frame() -> Surface { ClockRenderer.surface(for: Date(), size: renderSize, accent: accentColor) }
        try? await pixoo.present(frame(), fade: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Double(max(2, intervalSeconds))))
        while nativeLoopAlive {
            try? await pixoo.present(frame(), fade: false)
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Album cover: fade in, then hold for the dwell (re-sending only when a new cover arrives).
    private func presentCover(on pixoo: PixooBackend, multi: Bool) async {
        try? await pixoo.present(artFrame ?? ClockRenderer.surface(for: Date(), size: renderSize), fade: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Double(max(2, intervalSeconds))))
        var lastArtVersion = artVersion
        while nativeLoopAlive {
            if artVersion != lastArtVersion {
                lastArtVersion = artVersion
                if let art = artFrame { try? await pixoo.present(art, fade: false) }
            }
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func attemptReconnect() async {
        guard let backend else { return }
        do {
            try await backend.connect()
            isConnected = true
            statusText = "Connected: \(backend.label)"
        } catch {
            isConnected = false
        }
    }

    private func sendSafely(_ frame: Surface, last lastFrame: inout Surface?) async {
        guard let backend else { isConnected = false; return }
        do {
            try await backend.send(frame)
            lastFrame = frame
        } catch {
            // Transient drop — the loop marks us disconnected and retries the connect.
            isConnected = false
            lastFrame = nil
        }
    }
}
