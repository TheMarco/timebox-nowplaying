import Foundation
import TimeboxKit

/// Digital clock: a 12-hour "H:MM" time with a flashing red colon, plus a scrolling
/// "Artist — Title" ticker. Two native layouts:
///
/// - **16×16** (Timebox): the original cramped layout — a 3×5 digit font pinned up top and
///   a 5px ticker below. Reproduced exactly.
/// - **64×64** (Pixoo): a bold, neon layout — the shared `PixelFont` scaled ×3 with a
///   top-light→accent gradient fill, a soft glow halo, an accent radial bloom and underline,
///   all tinted by the album-art `accent`. The scrolling title is drawn separately by the
///   Pixoo's own text engine in the bottom band.
enum DigitalClockRenderer {
    static func surface(for date: Date, ticker: String = "", scroll: Int = 0, size: Int,
                        tickerScale: Int = 1, accent: PixelRGB? = nil, calendar: Calendar = .current,
                        use24Hour: Bool = false) -> Surface {
        size == 16
            ? small(for: date, ticker: ticker, scroll: scroll, calendar: calendar, use24Hour: use24Hour)
            : large(for: date, ticker: ticker, scroll: scroll, size: size, tickerScale: tickerScale,
                    accent: accent, calendar: calendar, use24Hour: use24Hour)
    }

    // MARK: - Time tokens (shared)

    private enum Token { case digit(Int), colon }

    /// 12/24-hour "H:MM" as tokens, dropping a 12-hour leading-zero hour.
    private static func timeTokens(_ date: Date, calendar: Calendar, use24Hour: Bool) -> [Token] {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        var hour = comps.hour ?? 0
        if !use24Hour { hour %= 12; if hour == 0 { hour = 12 } }
        let minute = comps.minute ?? 0
        let h1 = hour / 10, h2 = hour % 10, m1 = minute / 10, m2 = minute % 10
        var tokens: [Token] = []
        if use24Hour || h1 != 0 { tokens.append(.digit(h1)) }
        tokens.append(.digit(h2)); tokens.append(.colon)
        tokens.append(.digit(m1)); tokens.append(.digit(m2))
        return tokens
    }

    private static func colonLit(_ date: Date, _ calendar: Calendar) -> Bool {
        (calendar.dateComponents([.second], from: date).second ?? 0) % 2 == 0   // flash once/sec
    }

    // MARK: - 16×16 (original Timebox layout)

    // Small time digits (5 tall). "1" is 1px wide; the rest are 3px.
    private static let glyphs: [[String]] = [
        ["###", "#.#", "#.#", "#.#", "###"], // 0
        ["#", "#", "#", "#", "#"],           // 1
        ["###", "..#", "###", "#..", "###"], // 2
        ["###", "..#", "###", "..#", "###"], // 3
        ["#.#", "#.#", "###", "..#", "..#"], // 4
        ["###", "#..", "###", "..#", "###"], // 5
        ["###", "#..", "###", "#.#", "###"], // 6
        ["###", "..#", "..#", "..#", "..#"], // 7
        ["###", "#.#", "###", "#.#", "###"], // 8
        ["###", "#.#", "###", "..#", "###"]  // 9
    ]

    private static func small(for date: Date, ticker: String, scroll: Int,
                              calendar: Calendar, use24Hour: Bool) -> Surface {
        var surface = Surface(width: 16, height: 16)
        let timeTopY = 2   // time occupies rows 2...6
        let tickerTopY = 9 // 5px ticker occupies rows 9...13

        let white = PixelRGB(red: 255, green: 255, blue: 255)
        let red = PixelRGB(red: 255, green: 40, blue: 40)
        let tickerColor = PixelRGB(red: 120, green: 170, blue: 255)

        func drawDigit(_ value: Int, atX originX: Int) {
            for (rowIndex, row) in glyphs[value].enumerated() {
                for (colIndex, char) in row.enumerated() where char == "#" {
                    surface.set(originX + colIndex, timeTopY + rowIndex, white)
                }
            }
        }
        func glyphWidth(_ value: Int) -> Int { glyphs[value].first?.count ?? 3 }

        let tokens = timeTokens(date, calendar: calendar, use24Hour: use24Hour)
        let colonWidth = 1
        func tokenWidth(_ t: Token) -> Int { if case let .digit(d) = t { return glyphWidth(d) }; return colonWidth }

        let widthSum = tokens.map(tokenWidth).reduce(0, +)
        let gap = (widthSum + (tokens.count - 1)) > 16 ? 0 : 1
        let totalW = widthSum + gap * (tokens.count - 1)

        var x = max(0, (16 - totalW + 1) / 2)
        let lit = colonLit(date, calendar)
        for (i, t) in tokens.enumerated() {
            switch t {
            case .digit(let d): drawDigit(d, atX: x)
            case .colon:
                if lit { surface.set(x, timeTopY + 1, red); surface.set(x, timeTopY + 3, red) }
            }
            x += tokenWidth(t) + (i < tokens.count - 1 ? gap : 0)
        }

        // Ticker: scrolls in from the right edge and slides off the left as `scroll` grows.
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            for (i, col) in PixelFont.columns(for: text).enumerated() {
                let screenX = i - scroll + 16
                guard screenX >= 0, screenX < 16 else { continue }
                for y in 0..<PixelFont.height where col[y] { surface.set(screenX, tickerTopY + y, tickerColor) }
            }
        }
        return surface
    }

    // MARK: - 64×64 (rich neon Pixoo layout)

    private static func large(for date: Date, ticker: String, scroll: Int, size: Int,
                              tickerScale: Int, accent: PixelRGB?, calendar: Calendar,
                              use24Hour: Bool) -> Surface {
        var surface = Surface(width: size, height: size)
        let acc = Palette.vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        let lit = colonLit(date, calendar)

        let timeScale = 3
        let glyphH = PixelFont.height * timeScale            // 15
        let tokens = timeTokens(date, calendar: calendar, use24Hour: use24Hour)
        let gap = timeScale                                  // one blank source column between tokens

        let tokenCols = tokens.map { token -> [[Bool]] in
            switch token {
            case .digit(let d): return PixelFont.columns(for: String(d), tracking: 0)
            case .colon: return PixelFont.columns(for: ":", tracking: 0)
            }
        }
        let totalW = tokenCols.map { $0.count * timeScale }.reduce(0, +) + gap * (tokens.count - 1)
        let originX = (size - totalW) / 2
        let topY = max(0, (size / 2 - glyphH) / 2)           // centered in the top half

        // Soft accent glow behind the time.
        radialGlow(into: &surface, cx: size/2, cy: topY + glyphH/2, radius: 26, color: acc, peak: 0.26)

        // Gradient digit fill (top white → accent-tinted bottom) with a neon halo. The colon
        // is a flat accent and flashes once a second.
        let gradTop = PixelRGB(red: 255, green: 255, blue: 255)
        let gradBottom = Palette.mix(acc, PixelRGB(red: 255, green: 255, blue: 255), 0.25)
        var x = originX
        for (i, cols) in tokenCols.enumerated() {
            let isColon: Bool = { if case .colon = tokens[i] { return true }; return false }()
            if !(isColon && !lit) {
                blitGlow(cols, originX: x, originY: topY, scale: timeScale, halo: acc, into: &surface)
                blit(cols, originX: x, originY: topY, scale: timeScale,
                     gradTop: gradTop, gradBottom: gradBottom, flat: isColon ? acc : nil,
                     glyphH: glyphH, into: &surface)
            }
            x += cols.count * timeScale + (i < tokens.count - 1 ? gap : 0)
        }

        // Accent underline directly beneath the time (edge-faded). Kept clear of the bottom
        // band where the Pixoo's native text engine scrolls the title.
        let black = PixelRGB(red: 0, green: 0, blue: 0)
        let ulY = topY + glyphH + 2
        let ulHalf = totalW/2 + 2
        if ulHalf > 0 {
            for bx in (size/2 - ulHalf)...(size/2 + ulHalf) {
                let edge = min(bx - (size/2 - ulHalf), (size/2 + ulHalf) - bx)
                let a = min(1.0, Double(edge) / 5.0)
                surface.set(bx, ulY, Palette.mix(black, acc, 0.9 * a))
            }
        }

        // Fallback streamed ticker. On the Pixoo the title is drawn by the device's native text
        // engine (smoother than HTTP streaming), so `ticker` is normally empty here; this only
        // renders if a caller streams the title in-frame.
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let tickerH = PixelFont.height * tickerScale
            let tickerTopY = size - tickerH - 3
            for (i, col) in PixelFont.columns(for: text).enumerated() {
                let screenX = i * tickerScale - scroll + size
                if screenX <= -tickerScale || screenX >= size { continue }
                for y in 0..<PixelFont.height where col[y] {
                    for dx in 0..<tickerScale {
                        for dy in 0..<tickerScale {
                            surface.set(screenX + dx, tickerTopY + y * tickerScale + dy, acc)
                        }
                    }
                }
            }
        }
        return surface
    }

    /// Blit `PixelFont` columns as `scale`×`scale` blocks; digits get a vertical gradient
    /// (by row), a `flat` color overrides it (used for the colon).
    private static func blit(_ columns: [[Bool]], originX: Int, originY: Int, scale: Int,
                             gradTop: PixelRGB, gradBottom: PixelRGB, flat: PixelRGB?,
                             glyphH: Int, into surface: inout Surface) {
        for (cx, col) in columns.enumerated() {
            for (cy, on) in col.enumerated() where on {
                let px = originX + cx * scale, py = originY + cy * scale
                let t = Double(cy * scale) / Double(max(1, glyphH - 1))
                let color = flat ?? Palette.mix(gradTop, gradBottom, t)
                for dy in 0..<scale { for dx in 0..<scale { surface.set(px + dx, py + dy, color) } }
            }
        }
    }

    /// A 1px neon halo around the glyph, painted only onto currently-black pixels.
    private static func blitGlow(_ columns: [[Bool]], originX: Int, originY: Int, scale: Int,
                                 halo: PixelRGB, into surface: inout Surface) {
        let black = PixelRGB(red: 0, green: 0, blue: 0)
        let h = Palette.mix(black, halo, 0.55)
        for (cx, col) in columns.enumerated() {
            for (cy, on) in col.enumerated() where on {
                let px = originX + cx * scale, py = originY + cy * scale
                for dy in -1...scale { for dx in -1...scale {
                    let xx = px + dx, yy = py + dy
                    guard xx >= 0, yy >= 0, xx < surface.width, yy < surface.height else { continue }
                    if surface.pixels[yy * surface.width + xx] == black { surface.set(xx, yy, h) }
                }}
            }
        }
    }

    private static func radialGlow(into surface: inout Surface, cx: Int, cy: Int, radius: Int,
                                   color: PixelRGB, peak: Double) {
        guard radius > 0 else { return }
        for y in 0..<surface.height { for x in 0..<surface.width {
            let d = (Double((x-cx)*(x-cx) + (y-cy)*(y-cy))).squareRoot()
            if d > Double(radius) { continue }
            let a = peak * (1 - d / Double(radius))
            let base = surface.pixels[y * surface.width + x]
            surface.set(x, y, Palette.mix(base, color, a))
        }}
    }
}
