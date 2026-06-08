import Foundation
import CoreText
import CoreGraphics

/// Rasterizes scrolling-title text from the bundled **Konami Classic** arcade font (crisp,
/// anti-aliasing off) into bitmap columns the LED renderers can blit — sharper and less bulky
/// than the hand-coded glyphs. Falls back to `PixelFont` if the font resource isn't present.
enum ArcadeFont {
    private static let pointSize: CGFloat = 8   // the font's native (crisp) pixel size

    private struct Face { let font: CTFont; let height: Int; let baseline: CGFloat }
    private static let face: Face? = load()

    /// Pixel height of a rasterized row (matches `PixelFont.height` in the fallback case).
    static var height: Int { face?.height ?? PixelFont.height }

    /// Whether the arcade font is available (else the renderers use `PixelFont`).
    static var isAvailable: Bool { face != nil }

    /// Columns left→right; each is `height` booleans top→bottom. Text is uppercased.
    static func columns(for text: String) -> [[Bool]] {
        guard let face else { return PixelFont.columns(for: text) }
        return rasterize(text.uppercased(), face: face)
    }

    private static func load() -> Face? {
        guard let url = Bundle.main.url(forResource: "KonamiClassic", withExtension: "otf"),
              let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let desc = descs.first else { return nil }
        let font = CTFontCreateWithFontDescriptor(desc, pointSize, nil)
        let height = max(1, Int((CTFontGetAscent(font) + CTFontGetDescent(font)).rounded(.up)))
        return Face(font: font, height: height, baseline: CTFontGetDescent(font).rounded())
    }

    private static func rasterize(_ text: String, face: Face) -> [[Bool]] {
        let attr: [CFString: Any] = [kCTFontAttributeName: face.font,
                                     kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)]
        guard let astr = CFAttributedStringCreate(nil, text as CFString, attr as CFDictionary) else { return [] }
        let line = CTLineCreateWithAttributedString(astr)
        let width = max(1, Int(CTLineGetTypographicBounds(line, nil, nil, nil).rounded(.up)))
        let h = face.height
        var buf = [UInt8](repeating: 0, count: width * h)
        guard let ctx = CGContext(data: &buf, width: width, height: h, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.setShouldAntialias(false)
        ctx.setAllowsAntialiasing(false)
        ctx.textPosition = CGPoint(x: 0, y: face.baseline)
        CTLineDraw(line, ctx)
        var cols: [[Bool]] = []
        cols.reserveCapacity(width)
        for x in 0..<width {
            var col = [Bool](repeating: false, count: h)
            for y in 0..<h {
                let row = h - 1 - y   // CG bitmap row 0 is the bottom
                col[y] = buf[row * width + x] > 127
            }
            cols.append(col)
        }
        return cols
    }
}
