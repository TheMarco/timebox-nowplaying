import Foundation
import TimeboxKit

/// Color helpers for the rich 64×64 renderers: a vivid accent derived from album art (so the
/// clocks and scrolling title reflect the music), plus the `vivid`/`mix` primitives the
/// analog and digital designs use. The 16×16 Timebox renderers don't use any of this.
enum Palette {
    /// A vivid dominant color from album art. Weights each pixel by saturation²·value so
    /// muddy/dark pixels don't dominate; returns nil for essentially grayscale art (callers
    /// then fall back to a default accent).
    static func accent(from surface: Surface) -> PixelRGB? {
        var sr = 0.0, sg = 0.0, sb = 0.0, wsum = 0.0
        for p in surface.pixels {
            let r = Double(p.red)/255, g = Double(p.green)/255, b = Double(p.blue)/255
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx <= 0 ? 0 : (mx - mn) / mx
            let w = sat * sat * mx          // favor saturated, bright pixels
            sr += r*w; sg += g*w; sb += b*w; wsum += w
        }
        guard wsum > 0.5 else { return nil }   // ~grayscale art → no usable accent
        return vivid(PixelRGB(red: byte(sr/wsum), green: byte(sg/wsum), blue: byte(sb/wsum)))
    }

    /// Push a color to a bright, saturated version (for accents/glows). Near-black inputs
    /// fall back to a pleasant blue.
    static func vivid(_ c: PixelRGB) -> PixelRGB {
        var r = Double(c.red)/255, g = Double(c.green)/255, b = Double(c.blue)/255
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx < 0.04 { return PixelRGB(red: 120, green: 180, blue: 255) }
        let mid = (mx + mn) / 2, sat = 1.6
        r = mid + (r-mid)*sat; g = mid + (g-mid)*sat; b = mid + (b-mid)*sat
        let scale = 0.95 / mx
        return PixelRGB(red: byte(r*scale), green: byte(g*scale), blue: byte(b*scale))
    }

    /// Linear blend from `a` (t=0) to `b` (t=1).
    static func mix(_ a: PixelRGB, _ b: PixelRGB, _ t: Double) -> PixelRGB {
        func l(_ x: UInt8, _ y: UInt8) -> UInt8 { byte((Double(x)*(1-t) + Double(y)*t) / 255) }
        return PixelRGB(red: l(a.red, b.red), green: l(a.green, b.green), blue: l(a.blue, b.blue))
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
}
