import Foundation
import CoreGraphics
import TimeboxKit

/// Digital clock: a 12-hour "H:MM" time plus a scrolling "Artist — Title" ticker. Two layouts:
///
/// - **16×16** (Timebox): the original cramped layout — a 3×5 digit font pinned up top and a
///   5px ticker below. Reproduced exactly.
/// - **64×64** (Pixoo): a "hero card" — a cinematic background (the album art darkened +
///   vignetted, or a procedural synthwave sun + perspective grid when there's no art) with a
///   real **7-segment LCD** time floating over it: chamfered segments, faint "ghost" unlit
///   segments, a soft glow, and a slight italic lean, tinted by the album-art `accent`. The
///   scrolling title is drawn separately by the Pixoo's own text engine in the bottom band,
///   which this leaves darkened for legibility.
enum DigitalClockRenderer {
    static func surface(for date: Date, ticker: String = "", scroll: Int = 0, size: Int,
                        tickerScale: Int = 1, accent: PixelRGB? = nil, art: Surface? = nil,
                        calendar: Calendar = .current, use24Hour: Bool = false) -> Surface {
        size == 16
            ? small(for: date, ticker: ticker, scroll: scroll, calendar: calendar, use24Hour: use24Hour)
            : large(for: date, ticker: ticker, scroll: scroll, size: size, tickerScale: tickerScale,
                    accent: accent, art: art, calendar: calendar, use24Hour: use24Hour)
    }

    // MARK: - Time tokens (shared)

    private enum Token { case digit(Int), colon }

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
        let timeTopY = 2
        let tickerTopY = 9

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

    // MARK: - 64×64 (hero card)

    private static func large(for date: Date, ticker: String, scroll: Int, size: Int,
                              tickerScale: Int, accent: PixelRGB?, art: Surface?,
                              calendar: Calendar, use24Hour: Bool) -> Surface {
        var s = Surface(width: size, height: size)
        let acc = Palette.vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        let titleBand = 16   // bottom rows reserved for the native scrolling title

        if let art, art.width == size, art.height == size {
            artBackground(into: &s, art: art, accent: acc, titleBand: titleBand)
        } else {
            synthwave(into: &s, accent: acc, titleBand: titleBand)
        }

        drawLCDTime(into: &s, date: date, accent: acc, topY: 6, height: 26,
                    calendar: calendar, use24Hour: use24Hour)

        // Streamed "Artist — Title" ticker in the Konami arcade font (crisp, 1:1 device px).
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let cols = ArcadeFont.columns(for: text)
            let fh = ArcadeFont.height
            let ty = size - fh - 4
            let tickerColor = Palette.mix(acc, PixelRGB(red: 255, green: 255, blue: 255), 0.35)
            for (i, col) in cols.enumerated() {
                let sx = i - scroll + size           // enters from the right edge
                if sx < 0 || sx >= size { continue }
                for gy in 0..<fh where col[gy] { s.set(sx, ty + gy, tickerColor) }
            }
        }
        _ = tickerScale
        return s
    }

    /// Scroll distance (device px) for the title to fully enter from the right and exit left.
    static func tickerSpan(for text: String, size: Int, tickerScale: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if size == 16 { return PixelFont.columns(for: trimmed).count * tickerScale + size }
        return ArcadeFont.columns(for: trimmed).count + size   // 1:1 arcade font
    }

    // MARK: - 7-segment LCD time

    // Segments a,b,c,d,e,f,g.
    private static let segMap: [Int: [Bool]] = [
        0: [true,true,true,true,true,true,false], 1: [false,true,true,false,false,false,false],
        2: [true,true,false,true,true,false,true], 3: [true,true,true,true,false,false,true],
        4: [false,true,true,false,false,true,true], 5: [true,false,true,true,false,true,true],
        6: [true,false,true,true,true,true,true], 7: [true,true,true,false,false,false,false],
        8: [true,true,true,true,true,true,true], 9: [true,true,true,true,false,true,true]
    ]

    /// Draw the time as glowing 7-segment LCD digits (with faint ghost segments + italic lean),
    /// composited over whatever `s` already holds.
    private static func drawLCDTime(into s: inout Surface, date: Date, accent: PixelRGB,
                                    topY: Int, height dh: Double, calendar: Calendar, use24Hour: Bool) {
        let size = s.width, ss = 8, dim = size * ss
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setShouldAntialias(true)
        ctx.scaleBy(x: CGFloat(ss), y: CGFloat(ss))
        ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)   // author top-down
        let cs = CGColorSpaceCreateDeviceRGB()
        func cg(_ c: PixelRGB, _ a: Double) -> CGColor {
            CGColor(colorSpace: cs, components: [Double(c.red)/255, Double(c.green)/255, Double(c.blue)/255, a])!
        }

        let dw = 12.0, t = 3.0, gap = 1.0, colonW = 5.0
        let tokens = timeTokens(date, calendar: calendar, use24Hour: use24Hour)
        func tw(_ tk: Token) -> Double { if case .colon = tk { return colonW }; return dw }
        let total = tokens.map(tw).reduce(0, +) + gap * Double(tokens.count - 1)
        var x = (Double(size) - total) / 2
        let oy = Double(topY)
        let skew = 1.6   // px of italic lean across the digit height

        func shear(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: px + skew * (1 - (py - oy)/dh), y: py) }
        func hbar(_ ox: Double, _ yc: Double, _ w: Double) -> CGPath {
            let p = CGMutablePath(), i = 0.6
            let pts = [(ox+t*0.5+i,yc),(ox+t+i,yc-t*0.5),(ox+w-t-i,yc-t*0.5),(ox+w-t*0.5-i,yc),(ox+w-t-i,yc+t*0.5),(ox+t+i,yc+t*0.5)]
            p.move(to: shear(pts[0].0, pts[0].1)); for k in 1..<pts.count { p.addLine(to: shear(pts[k].0, pts[k].1)) }; p.closeSubpath(); return p
        }
        func vbar(_ xc: Double, _ oyy: Double, _ h: Double) -> CGPath {
            let p = CGMutablePath(), i = 0.6
            let pts = [(xc,oyy+t*0.5+i),(xc+t*0.5,oyy+t+i),(xc+t*0.5,oyy+h-t-i),(xc,oyy+h-t*0.5-i),(xc-t*0.5,oyy+h-t-i),(xc-t*0.5,oyy+t+i)]
            p.move(to: shear(pts[0].0, pts[0].1)); for k in 1..<pts.count { p.addLine(to: shear(pts[k].0, pts[k].1)) }; p.closeSubpath(); return p
        }
        func segPaths(_ ox: Double) -> [CGPath] {
            [ hbar(ox, oy+t*0.5, dw),                       // a
              vbar(ox+dw-t*0.5, oy, dh/2+t*0.5),            // b
              vbar(ox+dw-t*0.5, oy+dh/2-t*0.5, dh/2+t*0.5), // c
              hbar(ox, oy+dh-t*0.5, dw),                    // d
              vbar(ox+t*0.5, oy+dh/2-t*0.5, dh/2+t*0.5),    // e
              vbar(ox+t*0.5, oy, dh/2+t*0.5),               // f
              hbar(ox, oy+dh/2, dw) ]                       // g
        }

        let core = Palette.mix(PixelRGB(red: 255, green: 255, blue: 255), accent, 0.18)
        for tk in tokens {
            switch tk {
            case .digit(let d):
                let segs = segPaths(x), on = segMap[d]!
                for p in segs { ctx.addPath(p) }; ctx.setFillColor(cg(accent, 0.12)); ctx.fillPath()   // ghost
                let litPath = CGMutablePath(); for (k, p) in segs.enumerated() where on[k] { litPath.addPath(p) }
                ctx.addPath(litPath); ctx.setStrokeColor(cg(accent, 0.5)); ctx.setLineWidth(2.2); ctx.setLineJoin(.round); ctx.strokePath()  // glow
                ctx.addPath(litPath); ctx.setFillColor(cg(core, 1)); ctx.fillPath()
                x += dw + gap
            case .colon:
                let cxp = x + colonW/2, r = t*0.55
                let dots = colonLit(date, calendar)
                for cy in [oy + dh*0.34, oy + dh*0.66] {
                    let rect = CGRect(x: shear(cxp, cy).x - r, y: cy - r, width: r*2, height: r*2)
                    ctx.addEllipse(in: rect); ctx.setFillColor(cg(accent, 0.12)); ctx.fillPath()
                    if dots {
                        ctx.addEllipse(in: rect); ctx.setStrokeColor(cg(accent, 0.5)); ctx.setLineWidth(2.0); ctx.strokePath()
                        ctx.addEllipse(in: rect); ctx.setFillColor(cg(core, 1)); ctx.fillPath()
                    }
                }
                x += colonW + gap
            }
        }

        guard let img = ctx.makeImage() else { return }
        let bpr = size*4; var buf = [UInt8](repeating: 0, count: bpr*size)
        guard let dctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bpr,
                                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        dctx.interpolationQuality = .high
        dctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<size { for xx in 0..<size {
            let o = y*bpr + xx*4
            let a = Double(buf[o+3]) / 255
            if a <= 0.003 { continue }
            let base = s.at(xx, y)   // composite premultiplied-over
            s.set(xx, y, PixelRGB(red: byte(Double(buf[o])/255 + Double(base.red)/255*(1-a)),
                                  green: byte(Double(buf[o+1])/255 + Double(base.green)/255*(1-a)),
                                  blue: byte(Double(buf[o+2])/255 + Double(base.blue)/255*(1-a))))
        }}
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }

    // MARK: - Backgrounds

    /// Album art, darkened + vignetted, with a strong scrim under the title band.
    private static func artBackground(into s: inout Surface, art: Surface, accent: PixelRGB, titleBand: Int) {
        let size = s.width
        let cx = Double(size)/2, cy = Double(size)/2, maxd = (Double(size)/2) * 1.18
        for y in 0..<size { for x in 0..<size {
            var c = Palette.darken(art.at(x, y), 0.42)
            let d = (((Double(x)-cx)*(Double(x)-cx) + (Double(y)-cy)*(Double(y)-cy)).squareRoot()) / maxd
            c = Palette.darken(c, 1 - min(0.6, d*0.6))                 // radial vignette
            let intoBand = y - (size - titleBand)
            if intoBand > -3 {                                         // title band → near-black so the native ticker reads
                let f = min(1.0, Double(intoBand + 3) / Double(titleBand))
                c = Palette.mix(c, PixelRGB(red: 4, green: 5, blue: 8), min(0.96, f * 1.15))
            }
            s.set(x, y, c)
        }}
        let ry = size - titleBand - 1                                 // faint accent rule
        for x in 4..<(size-4) {
            let edge = min(x-4, (size-5)-x)
            s.set(x, ry, Palette.mix(s.at(x, ry), accent, 0.5 * min(1.0, Double(edge)/6.0)))
        }
    }

    /// Retro "synthwave" fallback: gradient sky, a slit sun, and a perspective grid.
    private static func synthwave(into s: inout Surface, accent: PixelRGB, titleBand: Int) {
        let size = s.width
        let horizon = Int(Double(size) * 0.60)
        let skyTop = PixelRGB(red: 14, green: 6, blue: 34)
        let skyHorizon = Palette.mix(PixelRGB(red: 90, green: 20, blue: 90), accent, 0.35)
        for y in 0..<horizon { for x in 0..<size {
            s.set(x, y, Palette.mix(skyTop, skyHorizon, pow(Double(y)/Double(horizon), 1.6)))
        }}
        let sunR = Double(size) * 0.26
        let sx = Double(size)/2, sy = Double(horizon) - sunR*0.35
        let sunTop = PixelRGB(red: 255, green: 240, blue: 180)
        let sunBot = Palette.vivid(Palette.mix(accent, PixelRGB(red: 255, green: 60, blue: 140), 0.5))
        for y in 0..<horizon { for x in 0..<size {
            let dx = Double(x)-sx, dy = Double(y)-sy
            if dx*dx + dy*dy <= sunR*sunR {
                let t = (Double(y) - (sy - sunR)) / (2*sunR)
                var c = Palette.mix(sunTop, sunBot, max(0, min(1, t)))
                let below = Double(y) - sy
                if below > 0 {
                    let period = max(2, Int(2.0 + (1 - below/sunR) * 5.0))
                    if Int(below) % period == 0 { c = Palette.darken(c, 0.15) }
                }
                s.set(x, y, c)
            }
        }}
        for y in horizon..<size { for x in 0..<size {
            s.set(x, y, Palette.mix(PixelRGB(red: 18, green: 6, blue: 30),
                                    PixelRGB(red: 4, green: 2, blue: 10),
                                    Double(y-horizon)/Double(size-horizon)))
        }}
        let grid = Palette.vivid(accent)
        var i = 0
        while true {
            let y = horizon + Int(pow(Double(i)/10.0, 1.8) * Double(size - horizon))
            if y >= size { break }
            for x in 0..<size { s.set(x, y, Palette.mix(s.at(x, y), grid, 0.55)) }
            i += 1
        }
        let vpx = Double(size)/2
        for k in -7...7 {
            for y in horizon..<size {
                let p = Double(y - horizon) / Double(size - horizon)
                let xx = Int(vpx + Double(k) * p * (Double(size) * 0.16))
                if xx >= 0, xx < size { s.set(xx, y, Palette.mix(s.at(xx, y), grid, 0.35)) }
            }
        }
        for y in (size - titleBand)..<size { for x in 0..<size {
            let f = Double(y - (size - titleBand) + 1) / Double(titleBand)
            s.set(x, y, Palette.mix(s.at(x, y), PixelRGB(red: 4, green: 5, blue: 8), min(0.96, f * 1.15)))
        }}
    }
}
