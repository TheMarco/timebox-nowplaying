import Foundation
import TimeboxKit

/// Small 1:1 pixel-drawing helpers for the LED renderers: crisp scalable text (built on
/// `PixelFont`, with `$`/`%` glyphs it doesn't carry), filled rectangles, and an additive
/// radial glow. Everything draws at integer scale so it stays sharp on the panel.
enum PixelDraw {
    static let fontHeight = PixelFont.height   // 5

    // Glyphs PixelFont lacks but the usage gizmo needs.
    private static let extra: [Character: [String]] = [
        "$": ["###", "##.", "###", ".##", "###"],
        "%": ["#.#", "..#", ".#.", "#..", "#.#"],
    ]

    /// Columns for `text` (each a `fontHeight` bool stack, top→bottom), `tracking` blank
    /// columns between glyphs (none trailing).
    static func columns(for text: String, tracking: Int = 1) -> [[Bool]] {
        var cols: [[Bool]] = []
        let chars = Array(text)
        for (idx, ch) in chars.enumerated() {
            if let glyph = extra[ch] {
                let w = glyph.map(\.count).max() ?? 0
                for x in 0..<w {
                    var col = [Bool](repeating: false, count: fontHeight)
                    for y in 0..<fontHeight {
                        let row = Array(glyph[y])
                        col[y] = x < row.count && row[x] == "#"
                    }
                    cols.append(col)
                }
            } else {
                cols.append(contentsOf: PixelFont.columns(for: String(ch), tracking: 0))
            }
            if idx < chars.count - 1 {
                for _ in 0..<tracking { cols.append([Bool](repeating: false, count: fontHeight)) }
            }
        }
        return cols
    }

    /// Rendered width (device px) of `text` at `scale`.
    static func width(of text: String, scale: Int = 1, tracking: Int = 1) -> Int {
        columns(for: text, tracking: tracking).count * scale
    }

    /// Draw `text` with its top-left at (`x`,`y`). `shadow`, when set, draws a crisp hard
    /// drop-shadow one logical pixel down-right (never a soft/anti-aliased halo).
    static func text(into s: inout Surface, _ text: String, x: Int, y: Int, scale: Int = 1,
                     color: PixelRGB, shadow: PixelRGB? = nil, tracking: Int = 1) {
        let cols = columns(for: text, tracking: tracking)
        func pass(_ dx: Int, _ dy: Int, _ c: PixelRGB) {
            for (i, col) in cols.enumerated() {
                for r in 0..<fontHeight where col[r] {
                    let bx = x + i * scale + dx, by = y + r * scale + dy
                    for sy in 0..<scale { for sx in 0..<scale { s.set(bx + sx, by + sy, c) } }
                }
            }
        }
        if let shadow { pass(1, 1, shadow) }   // crisp 1px drop shadow
        pass(0, 0, color)
    }

    /// Draw `text` horizontally centered in `[0, width)` at vertical `y`.
    static func textCentered(into s: inout Surface, _ text: String, y: Int, scale: Int = 1,
                             color: PixelRGB, shadow: PixelRGB? = nil, tracking: Int = 1) {
        let w = width(of: text, scale: scale, tracking: tracking)
        self.text(into: &s, text, x: (s.width - w) / 2, y: y, scale: scale,
                  color: color, shadow: shadow, tracking: tracking)
    }

    /// Filled rectangle (clipped by `Surface.set`).
    static func fillRect(into s: inout Surface, x: Int, y: Int, w: Int, h: Int, _ c: PixelRGB) {
        for yy in y..<(y + h) { for xx in x..<(x + w) { s.set(xx, yy, c) } }
    }

    /// Additive radial glow centered at (`cx`,`cy`) — brightens toward `color` with a soft
    /// quadratic falloff out to `radius`. Great for auras and warm backgrounds.
    static func radialGlow(into s: inout Surface, cx: Double, cy: Double, radius: Double,
                           color: PixelRGB, strength: Double) {
        guard radius > 0 else { return }
        let minX = max(0, Int(cx - radius)), maxX = min(s.width - 1, Int(cx + radius))
        let minY = max(0, Int(cy - radius)), maxY = min(s.height - 1, Int(cy + radius))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY...maxY { for x in minX...maxX {
            let dx = Double(x) - cx, dy = Double(y) - cy
            let d = (dx * dx + dy * dy).squareRoot() / radius
            if d >= 1 { continue }
            let f = (1 - d) * (1 - d) * strength
            s.set(x, y, Palette.screenAdd(s.at(x, y), color, f))
        }}
    }
}
