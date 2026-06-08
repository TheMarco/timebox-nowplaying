import Foundation
import TimeboxKit

/// A size-agnostic RGB pixel buffer, row-major with the top-left pixel first.
///
/// The `timebox-studio` library's `PixelFrame` is fixed at 16×16 (the Timebox Evo's
/// panel). The Pixoo 64 is 64×64 over WiFi, so the render loop works in this
/// device-independent `Surface` and each backend adapts it at the send boundary:
/// the Timebox backend converts a 16×16 surface to a `PixelFrame`; the Pixoo backend
/// serializes the raw bytes to base64. Reuses the library's `PixelRGB` value type.
struct Surface: Equatable {
    let width: Int
    let height: Int
    var pixels: [PixelRGB]

    /// A blank (or solid-filled) surface of the given size.
    init(width: Int, height: Int, fill color: PixelRGB = PixelRGB(red: 0, green: 0, blue: 0)) {
        self.width = width
        self.height = height
        self.pixels = Array(repeating: color, count: width * height)
    }

    /// Wrap an existing pixel array; returns nil if the count doesn't match `width*height`.
    init?(width: Int, height: Int, pixels: [PixelRGB]) {
        guard pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Set a pixel, ignoring out-of-bounds coordinates (so renderers can draw freely).
    mutating func set(_ x: Int, _ y: Int, _ color: PixelRGB) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        pixels[y * width + x] = color
    }

    /// Read a pixel (no bounds check — callers stay in range).
    func at(_ x: Int, _ y: Int) -> PixelRGB { pixels[y * width + x] }
}

extension Surface {
    /// Convert a 16×16 surface to the library's `PixelFrame` for the Bluetooth path.
    /// Throws if the surface isn't exactly the Timebox's 16×16.
    func toPixelFrame() throws -> PixelFrame {
        try PixelFrame(pixels: pixels)
    }

    /// Adopt a `PixelFrame` (always 16×16) as a `Surface`.
    init(_ frame: PixelFrame) {
        self.width = PixelFrame.width
        self.height = PixelFrame.height
        self.pixels = frame.pixels
    }
}
