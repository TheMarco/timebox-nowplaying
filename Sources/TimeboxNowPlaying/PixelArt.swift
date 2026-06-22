import Foundation
import TimeboxKit

/// Lo-fi pixel-art restyling of album covers — ported from the iOS app. Three families:
///   • **adaptive** — a per-album palette (median-cut) so each cover keeps its own colors;
///   • **fixed** — a console palette (Game Boy, PICO-8, C64, …) for a strong shared identity;
///   • **ramp** — luminance mapped onto a monochrome/CRT/thermal gradient.
/// All use self-tuning 8×8 ordered (Bayer) dithering. Operates on the device-resolution `Surface`
/// after `ImageEnhance.punchUp`, before sending. (Clocks/weather were intentionally not ported.)
enum PixelArt {
    struct Style {
        let id: String
        let palette: Palette
        let dither: Double
    }
    enum Palette {
        case adaptive(colors: Int)
        case fixed([PixelRGB])
        case ramp([PixelRGB])
    }

    static let off = "Off"

    static let presets: [Style] = [
        // Adaptive — keep each album's own colours.
        Style(id: "Soft",        palette: .adaptive(colors: 24), dither: 0.35),
        Style(id: "Classic",     palette: .adaptive(colors: 16), dither: 0.50),
        Style(id: "Crunchy",     palette: .adaptive(colors: 8),  dither: 0.90),
        // Fixed console palettes — a strong shared identity.
        Style(id: "Game Boy",    palette: .fixed(gameBoy),       dither: 0.80),
        Style(id: "PICO-8",      palette: .fixed(pico8),         dither: 0.55),
        Style(id: "C64",         palette: .fixed(c64),           dither: 0.55),
        Style(id: "NES",         palette: .fixed(nes),           dither: 0.45),
        Style(id: "ZX Spectrum", palette: .fixed(zxSpectrum),    dither: 0.70),
        Style(id: "CGA",         palette: .fixed(cga),           dither: 1.00),
        Style(id: "Vaporwave",   palette: .fixed(vaporwave),     dither: 0.60),
        Style(id: "1-bit",       palette: .fixed(oneBit),        dither: 1.00),
        // Monochrome / CRT ramps — luminance-mapped.
        Style(id: "Mono",        palette: .ramp(mono),           dither: 1.00),
        Style(id: "Sepia",       palette: .ramp(sepia),          dither: 0.90),
        Style(id: "Green CRT",   palette: .ramp(greenCRT),       dither: 0.90),
        Style(id: "Amber CRT",   palette: .ramp(amberCRT),       dither: 0.90),
        Style(id: "Virtual Boy", palette: .ramp(virtualBoy),     dither: 1.00),
        Style(id: "Thermal",     palette: .ramp(thermal),        dither: 0.70),
    ]

    static func preset(named id: String) -> Style? { presets.first { $0.id == id } }

    /// Restyle a surface to the style's palette. `dither` overrides the preset's dithering amount
    /// (pass 0 for clean palette mapping with no cross-hatch — used for the Claude data screens).
    static func stylize(_ surface: Surface, style: Style, dither: Double? = nil) -> Surface {
        let d = dither ?? style.dither
        switch style.palette {
        case .adaptive(let n): return quantize(surface, to: medianCut(surface.pixels, into: max(2, n)), dither: d)
        case .fixed(let p):    return quantize(surface, to: p, dither: d)
        case .ramp(let r):     return rampMap(surface, ramp: r, dither: d)
        }
    }

    // MARK: - Ramp (luminance → gradient)

    private static func rampMap(_ surface: Surface, ramp: [PixelRGB], dither: Double) -> Surface {
        guard ramp.count > 1 else { return surface }
        let n = ramp.count
        var out = surface.pixels
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let i = y * surface.width + x
                let l = luma(surface.pixels[i])
                let pos = l * Double(n - 1) + (bayer8[y & 7][x & 7] - 0.5) * dither
                out[i] = ramp[max(0, min(n - 1, Int(pos.rounded())))]
            }
        }
        return Surface(width: surface.width, height: surface.height, pixels: out) ?? surface
    }

    // MARK: - Quantize (ordered dither to a palette)

    private static func quantize(_ surface: Surface, to palette: [PixelRGB], dither: Double) -> Surface {
        guard palette.count > 1 else { return surface }
        // Dither amplitude ≈ the typical spacing between palette entries, so a pixel sitting
        // between two colours gets nudged across the boundary in a stable cross-hatch rather than
        // turning to noise. Self-tuning: a tight palette dithers gently, a sparse one strongly.
        let amp = dither * averageNearestDistance(palette)
        var out = surface.pixels
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let i = y * surface.width + x
                let p = surface.pixels[i]
                let t = (bayer8[y & 7][x & 7] - 0.5) * amp
                out[i] = nearest(in: palette,
                                 r: clampByte(Double(p.red) + t),
                                 g: clampByte(Double(p.green) + t),
                                 b: clampByte(Double(p.blue) + t))
            }
        }
        return Surface(width: surface.width, height: surface.height, pixels: out) ?? surface
    }

    // MARK: - Median-cut adaptive palette

    private static func medianCut(_ pixels: [PixelRGB], into count: Int) -> [PixelRGB] {
        guard !pixels.isEmpty else { return [] }
        var boxes = [pixels]
        while boxes.count < count {
            guard let idx = widestBoxIndex(boxes) else { break }
            let channel = widestChannel(boxes[idx])
            let sorted = boxes[idx].sorted { component($0, channel) < component($1, channel) }
            let mid = sorted.count / 2
            boxes[idx] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
        }
        return boxes.compactMap(average)
    }

    private static func widestBoxIndex(_ boxes: [[PixelRGB]]) -> Int? {
        var best: Int?, bestRange = -1
        for (i, box) in boxes.enumerated() where box.count > 1 {
            let r = (0..<3).map { channelRange(box, $0) }.max() ?? 0
            if r > bestRange { bestRange = r; best = i }
        }
        return best
    }

    private static func widestChannel(_ box: [PixelRGB]) -> Int {
        (0..<3).max { channelRange(box, $0) < channelRange(box, $1) } ?? 0
    }

    private static func channelRange(_ box: [PixelRGB], _ channel: Int) -> Int {
        var lo = 255, hi = 0
        for p in box { let v = Int(component(p, channel)); lo = min(lo, v); hi = max(hi, v) }
        return hi - lo
    }

    private static func component(_ p: PixelRGB, _ channel: Int) -> UInt8 {
        channel == 0 ? p.red : channel == 1 ? p.green : p.blue
    }

    private static func average(_ box: [PixelRGB]) -> PixelRGB? {
        guard !box.isEmpty else { return nil }
        var r = 0, g = 0, b = 0
        for p in box { r += Int(p.red); g += Int(p.green); b += Int(p.blue) }
        let n = box.count
        return PixelRGB(red: UInt8(r / n), green: UInt8(g / n), blue: UInt8(b / n))
    }

    // MARK: - Helpers

    private static func nearest(in palette: [PixelRGB], r: UInt8, g: UInt8, b: UInt8) -> PixelRGB {
        let R = Int(r), G = Int(g), B = Int(b)
        var best = palette[0], bestD = Int.max
        for c in palette {
            let dr = R - Int(c.red), dg = G - Int(c.green), db = B - Int(c.blue)
            let d = dr * dr + dg * dg + db * db
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    private static func averageNearestDistance(_ p: [PixelRGB]) -> Double {
        guard p.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<p.count {
            var best = Double.greatestFiniteMagnitude
            for j in 0..<p.count where j != i {
                let dr = Double(Int(p[i].red) - Int(p[j].red))
                let dg = Double(Int(p[i].green) - Int(p[j].green))
                let db = Double(Int(p[i].blue) - Int(p[j].blue))
                best = min(best, (dr * dr + dg * dg + db * db).squareRoot())
            }
            total += best
        }
        return total / Double(p.count)
    }

    private static func luma(_ p: PixelRGB) -> Double {
        (0.299 * Double(p.red) + 0.587 * Double(p.green) + 0.114 * Double(p.blue)) / 255.0
    }

    private static func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    private static func rgb(_ hex: UInt32) -> PixelRGB {
        PixelRGB(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    private static let bayer8: [[Double]] = {
        let m: [[Int]] = [
            [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
            [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
            [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
            [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
        ]
        return m.map { $0.map { Double($0) / 64.0 } }
    }()

    // MARK: - Palettes

    private static let gameBoy = [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F].map { rgb(UInt32($0)) }
    private static let pico8 = [
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    ].map { rgb(UInt32($0)) }
    private static let c64 = [
        0x000000, 0xFFFFFF, 0x880000, 0xAAFFEE, 0xCC44CC, 0x00CC55, 0x0000AA, 0xEEEE77,
        0xDD8855, 0x664400, 0xFF7777, 0x333333, 0x777777, 0xAAFF66, 0x0088FF, 0xBBBBBB,
    ].map { rgb(UInt32($0)) }
    private static let nes = [
        0x7C7C7C, 0x0000FC, 0x0000BC, 0x4428BC, 0x940084, 0xA80020, 0xA81000, 0x881400,
        0x503000, 0x007800, 0x006800, 0x005800, 0x004058, 0x000000,
        0xBCBCBC, 0x0078F8, 0x0058F8, 0x6844FC, 0xD800CC, 0xE40058, 0xF83800, 0xE45C10,
        0xAC7C00, 0x00B800, 0x00A800, 0x00A844, 0x008888,
        0xF8F8F8, 0x3CBCFC, 0x6888FC, 0x9878F8, 0xF878F8, 0xF85898, 0xF87858, 0xFCA044,
        0xF8B800, 0xB8F818, 0x58D854, 0x58F898, 0x00E8D8, 0x787878,
        0xFCFCFC, 0xA4E4FC, 0xB8B8F8, 0xD8B8F8, 0xF8B8F8, 0xF8A4C0, 0xF0D0B0, 0xFCE0A8,
        0xF8D878, 0xD8F878, 0xB8F8B8, 0xB8F8D8, 0x00FCFC, 0xF8D8F8,
    ].map { rgb(UInt32($0)) }
    private static let zxSpectrum = [
        0x000000, 0x0000D7, 0xD70000, 0xD700D7, 0x00D700, 0x00D7D7, 0xD7D700, 0xD7D7D7,
        0x0000FF, 0xFF0000, 0xFF00FF, 0x00FF00, 0x00FFFF, 0xFFFF00, 0xFFFFFF,
    ].map { rgb(UInt32($0)) }
    private static let cga = [0x000000, 0x55FFFF, 0xFF55FF, 0xFFFFFF].map { rgb(UInt32($0)) }
    private static let vaporwave = [
        0x1A0033, 0x5B2A86, 0xC774E8, 0xFF6AD5, 0x8DDFFF, 0x01CDFE, 0x05FFA1, 0xFFF5F5,
    ].map { rgb(UInt32($0)) }
    private static let oneBit = [0x000000, 0xFFFFFF].map { rgb(UInt32($0)) }

    private static let mono = [0x000000, 0x555555, 0xAAAAAA, 0xFFFFFF].map { rgb(UInt32($0)) }
    private static let sepia = [0x1A1208, 0x4A3420, 0x8A6A42, 0xC8A878, 0xF5E8C8].map { rgb(UInt32($0)) }
    private static let greenCRT = [0x001B00, 0x00451A, 0x00873E, 0x33CC55, 0x88FF88].map { rgb(UInt32($0)) }
    private static let amberCRT = [0x180A00, 0x4A2A00, 0x9A6400, 0xE0A000, 0xFFD060, 0xFFF0C0].map { rgb(UInt32($0)) }
    private static let virtualBoy = [0x000000, 0x550000, 0xAA0000, 0xFF0000].map { rgb(UInt32($0)) }
    private static let thermal = [
        0x000008, 0x1A0A4A, 0x6A1B9A, 0xD6336C, 0xFF6B1A, 0xFFD000, 0xFFFFFF,
    ].map { rgb(UInt32($0)) }
}
