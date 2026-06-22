import Foundation

/// Per-device timing/geometry the render loop reads so a single loop drives both the
/// Bluetooth-streamed 16×16 Timebox and the HTTP-paced 64×64 Pixoo.
struct DisplayProfile {
    /// Panel dimensions in pixels (square on both supported devices).
    let width: Int
    let height: Int
    /// Minimum interval between frames (seconds). The loop is deadline-based, so if a
    /// send takes longer than this (HTTP), it simply runs at the achievable rate.
    let tick: Double
    /// Crossfade frame count when switching between views.
    let crossfadeSteps: Int
    /// Extra delay between crossfade frames (ns). Zero on HTTP, where the round-trip paces.
    let crossfadeStepDelay: UInt64
    /// Device pixels the ticker advances per digital tick.
    let scrollStep: Int
    /// Integer scale of the pixel font for the digital clock's ticker (1 on 16×16).
    let tickerScale: Int
    /// Drive via the device's own rendering engine (static frames + native scrolling text +
    /// brightness fades) instead of streaming every frame. True for the Pixoo, whose HTTP
    /// API can't sustain smooth frame streaming; false for the Bluetooth-streamed Timebox.
    let drivesNatively: Bool

    static let timebox = DisplayProfile(
        width: 16, height: 16, tick: 0.2,
        crossfadeSteps: 6, crossfadeStepDelay: 40_000_000,
        scrollStep: 2, tickerScale: 1, drivesNatively: false
    )

    /// Pixoo 64: HTTP round-trips cap frame streaming at ~4 fps, so it's driven natively —
    /// the streaming-only fields below are unused for it.
    static let pixoo = DisplayProfile(
        width: 64, height: 64, tick: 0.1,
        crossfadeSteps: 5, crossfadeStepDelay: 0,
        scrollStep: 4, tickerScale: 2, drivesNatively: true
    )

    /// On-screen simulator: same 64×64 geometry as the Pixoo, but driven via the generic
    /// streamed loop (no network), so frames + cross-dissolves render straight to the window.
    static let simulator = DisplayProfile(
        width: 64, height: 64, tick: 0.08,
        crossfadeSteps: 8, crossfadeStepDelay: 28_000_000,
        scrollStep: 4, tickerScale: 2, drivesNatively: false
    )
}

/// A connected display the controller can push frames to. Connection is established by
/// the concrete backend (a Timebox device, or a Pixoo host) before it's handed here.
/// Main-actor-bound to match the controller and the original Bluetooth threading model.
@MainActor
protocol DisplayBackend: AnyObject {
    var profile: DisplayProfile { get }
    var isConnected: Bool { get }
    /// A short human label for the status line (e.g. the device name or host).
    var label: String { get }

    /// Establish (or re-establish, after a drop) the link to the target captured when the
    /// backend was created. Used both for the first connect and for loop reconnects.
    func connect() async throws
    func setBrightness(_ percent: Int) async throws
    func send(_ surface: Surface) async throws
    func disconnect()
}
