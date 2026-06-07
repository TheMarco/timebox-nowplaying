import Foundation
import CoreGraphics
import TimeboxKit

/// Renders an analog clock. Two designs, chosen by size:
///
/// - **≤16×16** (Timebox): the original minimal clock — supersampled, downsampled, and
///   sharpened so dots/hands read as crisp bright pixels on the tiny panel. Unchanged.
/// - **64×64** (Pixoo): a richer, beautiful clock — radial-gradient face, glowing bezel,
///   60 fine ticks with bright hour ticks, tapered glowing hands, an album-art `accent`
///   tint, a fixed warm second hand, and a center hub.
enum ClockRenderer {
    static func surface(for date: Date, size: Int, accent: PixelRGB? = nil,
                        calendar: Calendar = .current) -> Surface {
        size <= 16
            ? small(for: date, size: size, calendar: calendar)
            : large(for: date, size: size, accent: accent, calendar: calendar)
    }

    // MARK: - 16×16 (original Timebox design)

    private static func small(for date: Date, size: Int, calendar: Calendar) -> Surface {
        let supersample = size * 16            // 16× the panel, so 256 at size 16
        let unit = CGFloat(supersample) / 16   // pixels per 0…16 coordinate unit

        guard let context = CGContext(
            data: nil, width: supersample, height: supersample, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Surface(width: size, height: size) }

        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.scaleBy(x: unit, y: unit)      // work in 0…16 coordinates

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))

        let cx = 8.0, cy = 8.0
        func point(turns: Double, radius: Double) -> CGPoint {
            let theta = turns * 2 * .pi
            return CGPoint(x: cx + radius * sin(theta), y: cy + radius * cos(theta))
        }

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

        hand(turns: (hour + minute / 60.0) / 12.0, radius: 4.0, width: 1.4, rgb: (1, 1, 1))
        hand(turns: (minute + second / 60.0) / 60.0, radius: 6.2, width: 1.05, rgb: (0.62, 0.76, 1))
        hand(turns: second / 60.0, radius: 6.6, width: 0.6, rgb: (1, 0.27, 0.27))

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))

        guard let supersampled = context.makeImage() else { return Surface(width: size, height: size) }
        return downsampleSharp(supersampled, to: size)
    }

    /// Downsample with a sharpening curve — crisps the tiny clock's hands/dots to bright pixels.
    private static func downsampleSharp(_ image: CGImage, to size: Int) -> Surface {
        let bytesPerRow = size * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * size)
        guard let context = CGContext(
            data: &buffer, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Surface(width: size, height: size) }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        func sharpen(_ b: UInt8) -> UInt8 {
            let v = (Double(b) / 255.0 - 0.14) / (1.0 - 0.14)
            let out = pow(max(0, v), 0.78)
            return UInt8(max(0, min(255, (out * 255).rounded())))
        }

        var pixels = [PixelRGB]()
        pixels.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bytesPerRow + x * 4
                pixels.append(PixelRGB(red: sharpen(buffer[offset]),
                                       green: sharpen(buffer[offset + 1]),
                                       blue: sharpen(buffer[offset + 2])))
            }
        }
        return Surface(width: size, height: size, pixels: pixels) ?? Surface(width: size, height: size)
    }

    // MARK: - 64×64 (rich Pixoo design)

    private static func large(for date: Date, size: Int, accent: PixelRGB?, calendar: Calendar) -> Surface {
        let ss = 8
        let dim = size * ss
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Surface(width: size, height: size)
        }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(ss), y: CGFloat(ss))   // work in 0…size coordinates

        let cs = CGColorSpaceCreateDeviceRGB()
        let s = CGFloat(size)
        let cx = s / 2, cy = s / 2
        let R = s / 2 - 1.5                            // face radius

        let accv = Palette.vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        func cg(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            CGColor(colorSpace: cs, components: [r, g, b, a])!
        }
        func cgOf(_ c: PixelRGB, _ a: Double = 1) -> CGColor {
            cg(Double(c.red)/255, Double(c.green)/255, Double(c.blue)/255, a)
        }

        ctx.setFillColor(cg(0, 0, 0)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        func point(_ turns: Double, _ radius: Double) -> CGPoint {
            let t = turns * 2 * .pi
            return CGPoint(x: cx + radius * sin(t), y: cy + radius * cos(t))
        }

        // Face: radial gradient disc (deep indigo center → near-black rim) + a subtle accent bloom.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2)); ctx.clip()
        let faceGrad = CGGradient(colorsSpace: cs, colors: [
            cg(0.09, 0.10, 0.17), cg(0.04, 0.04, 0.08), cg(0.01, 0.01, 0.03)
        ] as CFArray, locations: [0, 0.7, 1])!
        ctx.drawRadialGradient(faceGrad, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: R, options: [])
        let bloom = CGGradient(colorsSpace: cs, colors: [cgOf(accv, 0.16), cgOf(accv, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: cx, y: cy + R*0.35), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy + R*0.35), endRadius: R*0.9, options: [])
        ctx.restoreGState()

        // Bezel: soft accent glow ring + crisp rim + inner highlight.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(cgOf(accv, 0.30)); ctx.setLineWidth(1.8)
        ctx.strokeEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2))
        ctx.setStrokeColor(cg(0.42, 0.50, 0.66)); ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2))
        ctx.setStrokeColor(cg(0.75, 0.82, 0.95, 0.7)); ctx.setLineWidth(0.3)
        ctx.strokeEllipse(in: CGRect(x: cx - (R-0.7), y: cy - (R-0.7), width: (R-0.7)*2, height: (R-0.7)*2))

        // Ticks: 60 fine minute ticks, brighter & longer at the 12 hours.
        for i in 0..<60 {
            let turns = Double(i) / 60.0
            let isHour = i % 5 == 0
            let outer = Double(R) - 1.6
            let inner = outer - (isHour ? 4.2 : 1.8)
            let p0 = point(turns, outer), p1 = point(turns, inner)
            ctx.setLineWidth(isHour ? 0.9 : 0.35)
            ctx.setStrokeColor(isHour ? cg(0.80, 0.86, 0.98) : cg(0.34, 0.39, 0.5))
            ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        }
        // Quarter accents: small bright dots at 12/3/6/9.
        for q in 0..<4 {
            let p = point(Double(q) / 4.0, Double(R) - 6.0)
            ctx.setFillColor(cgOf(accv, 0.95))
            ctx.fillEllipse(in: CGRect(x: p.x - 0.7, y: p.y - 0.7, width: 1.4, height: 1.4))
        }

        let comps = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let second = Double(comps.second ?? 0) + Double(comps.nanosecond ?? 0) / 1e9
        let minute = Double(comps.minute ?? 0) + second / 60.0
        let hour = Double((comps.hour ?? 0) % 12) + minute / 60.0

        // Tapered hand (kite polygon) with a soft glow underneath.
        func hand(turns: Double, length: Double, baseWidth: Double, tail: Double,
                  color: PixelRGB, glow: PixelRGB, glowWidth: Double) {
            let t = turns * 2 * .pi
            let dx = sin(t), dy = cos(t)            // tip direction
            let px = cos(t), py = -sin(t)           // perpendicular
            let tip = CGPoint(x: cx + length*dx, y: cy + length*dy)
            let back = CGPoint(x: cx - tail*dx, y: cy - tail*dy)
            let h = baseWidth/2
            let bL = CGPoint(x: cx + h*px, y: cy + h*py)
            let bR = CGPoint(x: cx - h*px, y: cy - h*py)
            ctx.setStrokeColor(cgOf(glow, 0.35)); ctx.setLineWidth(glowWidth); ctx.setLineCap(.round)
            ctx.move(to: back); ctx.addLine(to: tip); ctx.strokePath()
            ctx.setFillColor(cgOf(color))
            ctx.move(to: back); ctx.addLine(to: bL); ctx.addLine(to: tip); ctx.addLine(to: bR)
            ctx.closePath(); ctx.fillPath()
        }

        let lightBlue = PixelRGB(red: 150, green: 195, blue: 255)
        let minuteColor = Palette.mix(lightBlue, accv, 0.5)   // leans to the theme, stays bright
        let secColor = PixelRGB(red: 255, green: 78, blue: 60) // fixed warm — always pops
        hand(turns: hour/12.0, length: Double(R)*0.52, baseWidth: 3.0, tail: 3.2,
             color: PixelRGB(red: 238, green: 242, blue: 255), glow: lightBlue, glowWidth: 4.5)
        hand(turns: minute/60.0, length: Double(R)*0.78, baseWidth: 2.1, tail: 4.0,
             color: minuteColor, glow: minuteColor, glowWidth: 3.4)
        hand(turns: second/60.0, length: Double(R)*0.86, baseWidth: 0.9, tail: 6.0,
             color: secColor, glow: secColor, glowWidth: 2.2)

        // Center hub.
        ctx.setFillColor(cg(0.92, 0.95, 1.0))
        ctx.fillEllipse(in: CGRect(x: cx - 2.0, y: cy - 2.0, width: 4.0, height: 4.0))
        ctx.setFillColor(cgOf(secColor))
        ctx.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))

        guard let img = ctx.makeImage() else { return Surface(width: size, height: size) }
        return downsampleSmooth(img, to: size)
    }

    /// Downsample preserving smooth gradients/AA, with a gentle LED lift on dim pixels.
    private static func downsampleSmooth(_ image: CGImage, to size: Int) -> Surface {
        let bytesPerRow = size * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * size)
        guard let context = CGContext(
            data: &buffer, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Surface(width: size, height: size) }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        func lift(_ b: UInt8) -> UInt8 {
            let v = pow(Double(b)/255, 0.85)
            return UInt8(max(0, min(255, (v*255).rounded())))
        }

        var pixels = [PixelRGB]()
        pixels.reserveCapacity(size * size)
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bytesPerRow + x * 4
                pixels.append(PixelRGB(red: lift(buffer[offset]),
                                       green: lift(buffer[offset + 1]),
                                       blue: lift(buffer[offset + 2])))
            }
        }
        return Surface(width: size, height: size, pixels: pixels) ?? Surface(width: size, height: size)
    }
}
