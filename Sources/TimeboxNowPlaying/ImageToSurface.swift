import Foundation
import CoreGraphics
import TimeboxKit

/// Rasterizes a `CGImage` down to a square `Surface` of the device's resolution.
/// Mirrors the library's `ImageToPixelFrameConverter`, but for an arbitrary size so the
/// Pixoo 64 gets full-resolution 64×64 album art instead of an upscaled 16×16 thumbnail.
enum ImageToSurface {
    /// `interpolation` defaults to `.high` (smooth) — correct for photos / album art.
    static func surface(from image: CGImage, size: Int,
                        interpolation: CGInterpolationQuality = .high) -> Surface? {
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * size)

        guard let context = CGContext(
            data: &buffer, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        // CGBitmapContext buffer is top-left origin, row-major — matching both devices'
        // pixel order, so no flip/reorder is needed.
        var pixels = [PixelRGB]()
        pixels.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels.append(PixelRGB(
                    red: buffer[offset],
                    green: buffer[offset + 1],
                    blue: buffer[offset + 2]
                ))
            }
        }
        return Surface(width: size, height: size, pixels: pixels)
    }
}
