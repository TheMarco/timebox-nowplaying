import Foundation
import CoreGraphics
import TimeboxKit

/// Renders a 16x16 analog clock. Draws at 16x supersampling with CoreGraphics
/// anti-aliasing, then downsamples to 16x16 (high interpolation) for smooth,
/// anti-aliased hands and bright tick dots.
enum ClockRenderer {
    static func frame(for date: Date, calendar: Calendar = .current) -> PixelFrame {
        let scale = 16
        let size = 16 * scale // 256x256 supersample

        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return PixelFrame() }

        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale)) // work in 0...16 coordinates

        // Background.
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))

        let cx = 8.0, cy = 8.0
        // y-up context: 12 o'clock is +y (top), angle increases clockwise.
        func point(turns: Double, radius: Double) -> CGPoint {
            let theta = turns * 2 * .pi
            return CGPoint(x: cx + radius * sin(theta), y: cy + radius * cos(theta))
        }

        // Bright tick dots; quarter marks bigger/brighter.
        for i in 0..<12 {
            let p = point(turns: Double(i) / 12.0, radius: 6.8)
            let isQuarter = (i % 3 == 0)
            let radius = isQuarter ? 0.95 : 0.6
            let level: CGFloat = isQuarter ? 1.0 : 0.85
            context.setFillColor(red: level, green: level, blue: level, alpha: 1)
            context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }

        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double((comps.hour ?? 0) % 12)
        let minute = Double(comps.minute ?? 0)
        let second = Double(comps.second ?? 0)

        context.setLineCap(.round)
        func hand(turns: Double, radius: Double, width: Double, rgb: (CGFloat, CGFloat, CGFloat)) {
            context.setStrokeColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            context.setLineWidth(width)
            context.move(to: CGPoint(x: cx, y: cy))
            context.addLine(to: point(turns: turns, radius: radius))
            context.strokePath()
        }

        hand(turns: (hour + minute / 60.0) / 12.0, radius: 4.0, width: 1.4, rgb: (1, 1, 1))         // hour
        hand(turns: (minute + second / 60.0) / 60.0, radius: 6.2, width: 1.05, rgb: (0.62, 0.76, 1)) // minute
        hand(turns: second / 60.0, radius: 6.6, width: 0.6, rgb: (1, 0.27, 0.27))                    // second

        // Center hub.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))

        guard let supersampled = context.makeImage() else { return PixelFrame() }
        return downsample(supersampled)
    }

    private static func downsample(_ image: CGImage) -> PixelFrame {
        let width = PixelFrame.width, height = PixelFrame.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return PixelFrame() }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sharpen: drop the faintest anti-alias halo to black and brighten the
        // rest, so hands/dots read as crisp bright pixels instead of muddy gray.
        func sharpen(_ b: UInt8) -> UInt8 {
            let v = (Double(b) / 255.0 - 0.14) / (1.0 - 0.14)
            let out = pow(max(0, v), 0.78)
            return UInt8(max(0, min(255, (out * 255).rounded())))
        }

        var pixels = [PixelRGB]()
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels.append(PixelRGB(
                    red: sharpen(buffer[offset]),
                    green: sharpen(buffer[offset + 1]),
                    blue: sharpen(buffer[offset + 2])
                ))
            }
        }
        return (try? PixelFrame(pixels: pixels)) ?? PixelFrame()
    }
}
