import Foundation
import TimeboxKit

/// The latest frame + panel brightness the on-screen simulator window renders. Updated by
/// `SimulatorBackend` from the exact same render loop that drives the real Pixoo.
@MainActor
final class SimulatorScreen: ObservableObject {
    static let shared = SimulatorScreen()
    @Published var frame = Surface(width: 64, height: 64)
    @Published var brightness: Double = 1
}

/// A `DisplayBackend` that "sends" frames to an on-screen window instead of a device. It uses
/// the `.simulator` profile, so the controller runs the generic streamed loop and each frame
/// (including cross-dissolves between screens) lands straight in the window.
@MainActor
final class SimulatorBackend: DisplayBackend {
    let profile = DisplayProfile.simulator
    private let screen: SimulatorScreen
    private var connected = false

    init(screen: SimulatorScreen = .shared) { self.screen = screen }

    var isConnected: Bool { connected }
    var label: String { "Simulator" }

    func connect() async throws { connected = true; screen.brightness = 1 }
    func setBrightness(_ percent: Int) async throws { screen.brightness = Double(max(0, min(100, percent))) / 100 }
    func send(_ surface: Surface) async throws { screen.frame = surface }
    func disconnect() { connected = false }
}
