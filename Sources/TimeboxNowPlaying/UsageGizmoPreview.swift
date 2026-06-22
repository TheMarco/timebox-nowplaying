import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TimeboxKit

/// Headless preview for the usage gizmo: with `DUMP_USAGE=1` set, the app renders the screens
/// to PNGs (nearest-neighbor upscaled so the pixels are visible) and exits — handy for eyeballing
/// clawd and the layouts without a physical Pixoo. Not part of the normal runtime.
enum UsageGizmoPreview {
    static func dump(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let u = sample()
        let p = samplePlan()
        write(ClawdUsageRenderer.surface(.session, usage: u, plan: p, size: 64, phase: 1.0), "\(dir)/session.png")
        write(ClawdUsageRenderer.surface(.weekly, usage: u, plan: p, size: 64, phase: 1.0), "\(dir)/weekly.png")
        write(ClawdUsageRenderer.surface(.graph, usage: u, plan: p, size: 64, phase: 1.0, intro: 1), "\(dir)/graph.png")
        write(ClawdUsageRenderer.surface(.graph, usage: u, plan: p, size: 64, phase: 1.0, intro: 0.4), "\(dir)/graph_intro.png")
        write(ClawdUsageRenderer.surface(.session, usage: u, plan: .empty, size: 64, phase: 1.0), "\(dir)/session_nodata.png")
        var p66 = samplePlan(); p66.sessionPercent = 66
        write(ClawdUsageRenderer.surface(.session, usage: u, plan: p66, size: 64, phase: 0.0), "\(dir)/session_66.png")

        // Clawd by himself (native 24×15, centered).
        var hero = Surface(width: 64, height: 64)
        Clawd.draw(into: &hero, originX: (64 - Clawd.width) / 2, originY: (64 - Clawd.height) / 2)
        write(hero, "\(dir)/clawd.png")

        FileHandle.standardError.write(Data("Wrote usage previews to \(dir)\n".utf8))
    }

    /// Apply every PixelArt style to a colourful test image and write PNGs (verifies the port).
    static func dumpStyles(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var base = Surface(width: 64, height: 64)
        for y in 0..<64 {
            for x in 0..<64 {
                base.set(x, y, PixelRGB(red: UInt8(min(255, x * 4)),
                                        green: UInt8(min(255, y * 4)),
                                        blue: UInt8(min(255, (63 - x) * 4))))
            }
        }
        base = ImageEnhance.punchUp(base)
        write(base, "\(dir)/_base.png")
        for s in PixelArt.presets { write(PixelArt.stylize(base, style: s), "\(dir)/\(s.id).png") }

        // Claude usage screens under a few styles (verify the "style the Claude part" feature).
        let u = sample(), pl = samplePlan()
        let sess = ClawdUsageRenderer.surface(.session, usage: u, plan: pl, size: 64, phase: 1)
        let gr = ClawdUsageRenderer.surface(.graph, usage: u, plan: pl, size: 64, phase: 1, intro: 1)
        for id in ["Green CRT", "Game Boy", "PICO-8"] {
            if let st = PixelArt.preset(named: id) {
                write(PixelArt.stylize(sess, style: st, dither: 0), "\(dir)/_session_\(id).png")
                write(PixelArt.stylize(gr, style: st, dither: 0), "\(dir)/_graph_\(id).png")
            }
        }
        FileHandle.standardError.write(Data("Wrote \(PixelArt.presets.count) style previews to \(dir)\n".utf8))
    }

    private static func samplePlan() -> ClaudePlan {
        var p = ClaudePlan()
        p.planTier = "Max (5x)"
        p.sessionPercent = 20
        p.sessionResetsAt = Date().addingTimeInterval(3 * 3600 + 10 * 60)
        p.weeklyPercent = 2
        p.weeklyResetsAt = Date().addingTimeInterval(2 * 86_400 + 8 * 3600)
        return p
    }

    private static func sample() -> ClaudeUsage {
        var u = ClaudeUsage()
        u.todayTokens = 12_430_000
        u.todayCost = 8.20
        u.monthTokens = 342_000_000
        u.monthCost = 142.5
        u.topModel = "OPUS 4.8"

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEEEE"
        let pattern = [38_000_000, 9_000_000, 71_000_000, 22_000_000, 55_000_000, 4_000_000, 12_430_000]
        for offset in (0..<7).reversed() {
            let d = cal.date(byAdding: .day, value: -offset, to: today)!
            let tok = pattern[6 - offset]
            u.last7.append(.init(date: "", weekday: fmt.string(from: d).uppercased(),
                                 tokens: tok, cost: Double(tok) / 1_000_000))
            u.weekTokens += tok
        }
        u.generatedAt = Date()
        return u
    }

    private static func write(_ surface: Surface, _ path: String, scale: Int = 8) {
        let w = surface.width, h = surface.height
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h { for x in 0..<w {
            let p = surface.at(x, y), o = y * bpr + x * 4
            buf[o] = p.red; buf[o + 1] = p.green; buf[o + 2] = p.blue; buf[o + 3] = 255
        }}
        guard let small = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        else { return }

        let bw = w * scale, bh = h * scale
        guard let big = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        big.interpolationQuality = .none
        big.draw(small, in: CGRect(x: 0, y: 0, width: bw, height: bh))
        guard let img = big.makeImage() else { return }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
