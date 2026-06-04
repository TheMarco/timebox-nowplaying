import Foundation
import TimeboxKit

/// Linear crossfade between two 16x16 frames.
enum Blend {
    /// `steps` intermediate frames from `a` toward `b`, ending exactly on `b`.
    static func crossfade(from a: PixelFrame, to b: PixelFrame, steps: Int) -> [PixelFrame] {
        guard steps > 0 else { return [b] }
        var frames: [PixelFrame] = []
        frames.reserveCapacity(steps)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            var pixels = [PixelRGB]()
            pixels.reserveCapacity(a.pixels.count)
            for i in 0..<a.pixels.count {
                let ca = a.pixels[i], cb = b.pixels[i]
                pixels.append(PixelRGB(
                    red: lerp(ca.red, cb.red, t),
                    green: lerp(ca.green, cb.green, t),
                    blue: lerp(ca.blue, cb.blue, t)
                ))
            }
            frames.append((try? PixelFrame(pixels: pixels)) ?? b)
        }
        return frames
    }

    private static func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        let value = Double(a) * (1 - t) + Double(b) * t
        return UInt8(max(0, min(255, value.rounded())))
    }
}
