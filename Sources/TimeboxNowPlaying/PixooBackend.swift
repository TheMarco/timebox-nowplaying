import Foundation
import TimeboxKit

/// A Pixoo on the LAN, for the connect menu.
struct PixooDevice: Equatable {
    let name: String
    let host: String   // IP address, e.g. "192.168.1.42"
}

enum PixooError: LocalizedError {
    case unreachable(String)
    case deviceError(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): return "Couldn't reach the Pixoo at \(host). Check the IP and that it's on this Wi-Fi."
        case .deviceError(let code): return "The Pixoo rejected a command (error \(code))."
        case .badResponse: return "The Pixoo sent an unexpected response."
        }
    }
}

/// The Divoom Pixoo 64 path: a 64×64 panel driven over its WiFi HTTP JSON API
/// (`POST http://<ip>/post`). Frames go out via `Draw/SendHttpGif` carrying a base64
/// RGB buffer; the firmware wants a monotonically increasing `PicID` that's reset every
/// so often (it crashes on long GIF buffers), which this manages internally.
@MainActor
final class PixooBackend: DisplayBackend {
    let profile = DisplayProfile.pixoo
    private let host: String
    private let url: URL
    private let session: URLSession

    private var picId = 1
    private var connected = false

    /// The firmware accumulates pushed frames into a GIF buffer; reset before it grows
    /// large (the reference clients reset around 32; >~40 can crash the device).
    private let resetThreshold = 32

    init(host: String) {
        self.host = host
        self.url = URL(string: "http://\(host)/post")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    var isConnected: Bool { connected }
    var label: String { "Pixoo \(host)" }

    // MARK: - Discovery

    /// Ask Divoom's cloud which of its devices share this network's public IP. Returns
    /// the LAN IPs so the user can pick (or fall back to typing one). Best-effort: returns
    /// an empty list on any failure rather than throwing.
    static func discover() async -> [PixooDevice] {
        guard let endpoint = URL(string: "https://app.divoom-gz.com/Device/ReturnSameLANDevice") else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["DeviceList"] as? [[String: Any]] else { return [] }
            return list.compactMap { entry in
                guard let ip = entry["DevicePrivateIP"] as? String, !ip.isEmpty else { return nil }
                let name = (entry["DeviceName"] as? String) ?? "Pixoo"
                return PixooDevice(name: name, host: ip)
            }
        } catch {
            return []
        }
    }

    // MARK: - DisplayBackend

    func connect() async throws {
        // Seed the frame counter from the device and prove it's reachable. The first attempt
        // also triggers the macOS local-network permission prompt (which fails that attempt),
        // so retry for a few seconds to let the user tap "Allow" without re-clicking Connect.
        var lastError: Error?
        for attempt in 0..<6 {
            do {
                picId = try await currentGifId()
                if picId >= resetThreshold {
                    try? await resetGifId()
                    picId = 1
                }
                connected = true
                try? await setBrightness(100)
                return
            } catch {
                lastError = error
                connected = false
                if attempt < 5 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        _ = lastError
        throw PixooError.unreachable(host)
    }

    func setBrightness(_ percent: Int) async throws {
        let clamped = max(0, min(100, percent))
        try await post(["Command": "Channel/SetBrightness", "Brightness": clamped])
    }

    func send(_ surface: Surface) async throws {
        // Flatten to the device's expected [R,G,B, R,G,B, …] order (matches Surface's
        // row-major, top-left-first layout) and base64-encode.
        var bytes = [UInt8]()
        bytes.reserveCapacity(surface.pixels.count * 3)
        for px in surface.pixels {
            bytes.append(px.red); bytes.append(px.green); bytes.append(px.blue)
        }
        let encoded = Data(bytes).base64EncodedString()

        picId += 1
        if picId >= resetThreshold {
            try? await resetGifId()
            picId = 1
        }

        try await post([
            "Command": "Draw/SendHttpGif",
            "PicNum": 1,
            "PicWidth": profile.width,
            "PicOffset": 0,
            "PicID": picId,
            "PicSpeed": 1000,
            "PicData": encoded
        ])
    }

    func disconnect() {
        connected = false
    }

    // MARK: - Native smooth rendering (the Pixoo's own engine)

    /// A scrolling-text overlay the firmware animates itself — buttery smooth, unlike the
    /// ~4 fps we'd get streaming frames. Must sit on top of a frame sent via `send(_:)`.
    struct ScrollingText {
        let string: String
        let color: PixelRGB
        let y: Int
        var speed: Int = 50          // ms; lower = faster
    }

    /// Brightness ramp for the "fade through black" transition. A true cross-dissolve isn't
    /// possible (no fast frame path); fading the panel down, swapping the static image while
    /// dark, then fading up is the smoothest transition the command rate (~4/sec) allows.
    /// Eased so the dimming feels gradual rather than linear.
    private let fadeDown = [78, 56, 37, 21, 9, 0]
    private let fadeUp = [9, 21, 37, 56, 78, 100]

    func sendText(_ text: ScrollingText) async throws {
        try await post([
            "Command": "Draw/SendHttpText",
            "TextId": 1,
            "x": 0,
            "y": text.y,
            "dir": 0,                 // scroll left
            "font": 2,
            "TextWidth": profile.width,
            "speed": text.speed,
            "TextString": text.string,
            "color": String(format: "#%02X%02X%02X", text.color.red, text.color.green, text.color.blue),
        ])
    }

    /// Display a static frame, optionally fading through black on the way in and optionally
    /// overlaying native scrolling text. `fade: false` is used for live refreshes (a ticking
    /// clock, a new cover) so only entering a view dips the brightness.
    func present(_ surface: Surface, fade: Bool, text: ScrollingText? = nil) async throws {
        if fade { for v in fadeDown { try? await setBrightness(v) } }
        try await send(surface)
        if let text { try? await sendText(text) }
        if fade { for v in fadeUp { try? await setBrightness(v) } }
    }

    // MARK: - HTTP

    private func currentGifId() async throws -> Int {
        let json = try await post(["Command": "Draw/GetHttpGifId"])
        // Field is "PicId" in the reference firmware; default to 1 if absent.
        return (json["PicId"] as? Int) ?? 1
    }

    private func resetGifId() async throws {
        try await post(["Command": "Draw/ResetHttpGifId"])
    }

    /// POST a command and return the decoded JSON. Throws on transport failure or a
    /// non-zero `error_code` from the device.
    @discardableResult
    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            connected = false
            throw PixooError.unreachable(host)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Some firmware returns an empty body on success; treat that as OK.
            return [:]
        }
        if let code = json["error_code"] as? Int, code != 0 {
            throw PixooError.deviceError(code)
        }
        return json
    }
}
