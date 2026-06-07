import Foundation
import TimeboxBluetooth
import TimeboxKit

/// The original Divoom Timebox Evo path: a 16×16 panel driven over Bluetooth Classic SPP
/// via the `timebox-studio` library. Adapts the device-independent `Surface` to the
/// library's fixed 16×16 `PixelFrame` at the send boundary.
@MainActor
final class TimeboxBackend: DisplayBackend {
    let profile = DisplayProfile.timebox
    private let client = TimeboxClient()
    private let device: TimeboxDevice

    init(device: TimeboxDevice) {
        self.device = device
    }

    /// Paired devices whose name looks like a Timebox (for the connect menu).
    static func discover() -> [TimeboxDevice] {
        TimeboxClient.discoverTimeboxes()
    }

    var isConnected: Bool { client.isConnected }
    var label: String { device.name }

    func connect() async throws {
        try await client.connect(to: device)
        try? await client.setBrightness(100)
    }

    func setBrightness(_ percent: Int) async throws {
        try await client.setBrightness(percent)
    }

    func send(_ surface: Surface) async throws {
        try await client.send(image: try surface.toPixelFrame())
    }

    func disconnect() {
        client.disconnect()
    }
}
