import Foundation
import CoreGraphics
import AVFoundation
import TimeboxBluetooth
import TimeboxKit

/// Drives the Timebox: cycles the now-playing album art and one clock (analog or digital),
/// crossfading between them. The digital clock pins a 12-hour time up top and scrolls the
/// "Artist — Title" ticker below it. Mirrors the iOS "Now Playing" module — same render
/// loop, dynamic ticker dwell, and reconnect-on-drop resilience.
@MainActor
final class TimeboxController: ObservableObject {
    @Published var statusText = "Not connected"
    @Published var isConnected = false
    @Published var nowPlayingText = "—"
    @Published var intervalSeconds = 12        // album-art / analog dwell (seconds)
    @Published var showAlbumArt = true
    @Published var devices: [TimeboxDevice] = []

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

    private let client = TimeboxClient()
    private var artFrame: PixelFrame?
    private var artVersion = 0          // bumps on each new cover, so the loop re-sends it
    private var restartCycle = false    // new song: jump back to the cover before scrolling
    private var lastTrackKey = ""
    private var targetDevice: TimeboxDevice?

    // Stored as AnyObject so the property type doesn't force the macOS 14 floor onto the
    // whole class — the concrete `ShazamRecognizer` is gated `@available(macOS 14, *)`.
    private var shazamBox: AnyObject?

    private var loop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var running = false

    // The Timebox can't sustain fast full-frame streaming — ~5fps is sustainable.
    private let tick = 0.2
    private let scrollStep = 2          // pixels the ticker advances per tick (higher = faster)
    private let crossfadeSteps = 6

    // MARK: - Connection

    func refreshDevices() {
        devices = TimeboxClient.discoverTimeboxes()
    }

    func connect(to device: TimeboxDevice? = nil) {
        refreshDevices()
        guard let target = device ?? devices.first else {
            statusText = "No Timebox found — pair it, and allow Bluetooth for this app in System Settings → Privacy → Bluetooth"
            return
        }
        targetDevice = target
        statusText = "Connecting to \(target.name)…"
        Task {
            do {
                try await client.connect(to: target)
                isConnected = true
                statusText = "Connected: \(target.name)"
                try? await client.setBrightness(100)
                startLoops()
            } catch {
                isConnected = false
                statusText = "Connect failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        running = false
        loop?.cancel(); loop = nil
        stopSource()
        client.disconnect()
        isConnected = false
        artFrame = nil
        statusText = "Not connected"
    }

    // MARK: - Loops

    private func startLoops() {
        guard !running else { return }
        running = true
        startSource()
        loop = Task { await runLoop() }
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

    private func makeArt(_ cg: CGImage) -> PixelFrame? {
        (try? ImageToPixelFrameConverter.pixelFrame(from: cg, interpolation: .high))
            .map { ImageEnhance.punchUp($0) }
    }

    private func setArt(_ frame: PixelFrame) {
        artFrame = frame
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

    private func render(_ target: Target, scroll: Int) -> PixelFrame {
        switch target {
        case .albumArt: return artFrame ?? ClockRenderer.frame(for: Date())
        case .analog: return ClockRenderer.frame(for: Date())
        case .digital: return DigitalClockRenderer.frame(for: Date(), ticker: tickerText(), scroll: scroll)
        }
    }

    private func runLoop() async {
        let clock = ContinuousClock()
        var next = clock.now
        var lastFrame: PixelFrame?
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
                await sendSafely(ClockRenderer.frame(for: Date()), last: &lastFrame)
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
                if let from = lastFrame {
                    for f in Blend.crossfade(from: from, to: frame, steps: crossfadeSteps) {
                        if !running { break }
                        await sendSafely(f, last: &lastFrame)
                        try? await Task.sleep(nanoseconds: 40_000_000)
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
            next = next.advanced(by: .seconds(tick))
            if next < clock.now { next = clock.now }
            try? await clock.sleep(until: next, tolerance: .zero)
            elapsed += tick
            if target == .digital { scroll += scrollStep }   // scroll the title in/out

            // The digital clock's dwell is dynamic (ends once the title has scrolled away);
            // the cover and analog clock use the interval.
            let done: Bool
            switch target {
            case .digital:
                let text = tickerText()
                done = !text.isEmpty && scroll >= PixelFont.columns(for: text).count + 16
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

    private func attemptReconnect() async {
        guard let target = targetDevice else { return }
        do {
            try await client.connect(to: target)
            try? await client.setBrightness(100)
            isConnected = true
            statusText = "Connected: \(target.name)"
        } catch {
            isConnected = false
        }
    }

    private func sendSafely(_ frame: PixelFrame, last lastFrame: inout PixelFrame?) async {
        do {
            try await client.send(image: frame)
            lastFrame = frame
        } catch {
            // Transient drop — the loop marks us disconnected and retries the connect.
            isConnected = false
            lastFrame = nil
        }
    }
}
