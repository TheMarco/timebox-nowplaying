import Foundation
import TimeboxBluetooth
import TimeboxKit

/// Connects to the Timebox and alternates between the now-playing album artwork
/// and an analog clock, crossfading between the two.
@MainActor
final class TimeboxController: ObservableObject {
    @Published var statusText = "Not connected"
    @Published var isConnected = false
    @Published var nowPlayingText = "—"
    @Published var intervalSeconds = 10
    @Published var devices: [TimeboxDevice] = []

    enum ClockStyle { case analog, digital }
    @Published var clockStyle: ClockStyle = .analog

    private func clockFrame() -> PixelFrame {
        clockStyle == .digital
            ? DigitalClockRenderer.frame(for: Date())
            : ClockRenderer.frame(for: Date())
    }

    private let client = TimeboxClient()
    private var timer: Timer?
    private var showingClock = true
    private var secondsInMode = 0
    private var isSending = false
    private var lastSentFrame: PixelFrame?

    private let crossfadeSteps = 6
    private let crossfadeFrameNanos: UInt64 = 60_000_000 // 60 ms between blended frames

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
        statusText = "Connecting to \(target.name)…"
        Task {
            do {
                try await client.connect(to: target)
                isConnected = true
                statusText = "Connected: \(target.name)"
                try? await client.setBrightness(100) // full brightness
                startLoop()
            } catch {
                isConnected = false
                statusText = "Connect failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        stopLoop()
        client.disconnect()
        isConnected = false
        lastSentFrame = nil
        statusText = "Not connected"
    }

    // MARK: - Alternating loop

    private func startLoop() {
        stopLoop()
        secondsInMode = 0
        showingClock = true
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isConnected, !isSending else { return }
        secondsInMode += 1

        if secondsInMode > intervalSeconds {
            secondsInMode = 0
            showingClock.toggle()
            if showingClock {
                transition(to: clockFrame())
            } else {
                enterArtMode()
            }
            return
        }

        if showingClock {
            sendNow(clockFrame())
        }
    }

    private func enterArtMode() {
        NowPlaying.fetch { info in
            // Runs on the main thread; do non-Sendable work here, then hop to the actor.
            let text = [info.title, info.artist].compactMap { $0 }.joined(separator: " — ")
            let frame = info.artwork
                .flatMap { try? ImageToPixelFrameConverter.pixelFrame(from: $0, interpolation: .high) }
                .map { ImageEnhance.punchUp($0) }
            Task { @MainActor in
                self.nowPlayingText = text.isEmpty ? "Nothing playing" : text
                if let frame {
                    self.transition(to: frame)
                } else {
                    // Nothing playing / no artwork: stay on the clock.
                    self.showingClock = true
                    self.transition(to: self.clockFrame())
                }
            }
        }
    }

    // MARK: - Sending

    /// Send a single frame immediately (used for the live clock tick).
    private func sendNow(_ frame: PixelFrame) {
        guard isConnected, !isSending else { return }
        isSending = true
        Task {
            await send(frame)
            isSending = false
        }
    }

    /// Crossfade from the last displayed frame to `target`, then settle on it.
    private func transition(to target: PixelFrame) {
        guard isConnected, !isSending else { return }
        isSending = true
        let from = lastSentFrame
        Task {
            if let from {
                for frame in Blend.crossfade(from: from, to: target, steps: crossfadeSteps) {
                    await send(frame)
                    try? await Task.sleep(nanoseconds: crossfadeFrameNanos)
                }
            } else {
                await send(target)
            }
            isSending = false
        }
    }

    private func send(_ frame: PixelFrame) async {
        do {
            try await client.send(image: frame)
            lastSentFrame = frame
        } catch {
            isConnected = false
            statusText = "Disconnected: \(error.localizedDescription)"
            stopLoop()
        }
    }
}
