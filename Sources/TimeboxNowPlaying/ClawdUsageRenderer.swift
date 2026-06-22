import Foundation
import TimeboxKit

/// The Claude Code usage gizmo: a warm pixel-art view of plan usage, starring "clawd". Three
/// alternating 64×64 screens — **session** (5-hour window: % used, a bar, and the reset countdown),
/// **weekly** (the weekly window, same layout), and **graph** (the last 7 days of token usage).
/// Plan %/reset come from the companion app's cache (`ClaudePlan`); the graph from local logs.
/// Everything is crisp 1:1 pixels: bitmap text with hard drop-shadows, no anti-aliasing. clawd is
/// always his native 24×15. `phase` drives blink/bob; `intro` (0→1) grows the bars in.
enum ClawdUsageRenderer {
    enum Screen: CaseIterable { case session, weekly, graph }

    // Warm pixel palette.
    private static let orange = PixelRGB(red: 204, green: 120, blue: 92)
    private static let bright = PixelRGB(red: 242, green: 172, blue: 132)
    private static let core   = PixelRGB(red: 246, green: 238, blue: 228)
    private static let dim    = PixelRGB(red: 120, green: 74,  blue: 54)
    private static let track  = PixelRGB(red: 44,  green: 28,  blue: 22)
    private static let shadow = PixelRGB(red: 0,   green: 0,   blue: 0)    // 1px black drop shadow
    private static let bg     = PixelRGB(red: 10,  green: 7,   blue: 7)

    static func surface(_ screen: Screen, usage: ClaudeUsage, plan: ClaudePlan, size: Int,
                        phase: Double = 0, intro: Double = 1) -> Surface {
        if size <= 16 { return compact(screen, usage, plan, phase: phase) }
        var s = Surface(width: size, height: size)
        switch screen {
        case .session: gauge(into: &s, "SESSION", tier: plan.tierShort,
                             percent: plan.sessionPercent, resetsAt: plan.sessionResetsAt, phase: phase)
        case .weekly:  gauge(into: &s, "WEEKLY", tier: plan.tierShort,
                             percent: plan.weeklyPercent, resetsAt: plan.weeklyResetsAt, phase: phase)
        case .graph:   graph(into: &s, usage, phase: phase, intro: intro)
        }
        return shiftDown(s, by: 0)
    }

    /// Nudge the whole rendered screen down by `dy` pixels (top rows fill with background).
    private static func shiftDown(_ s: Surface, by dy: Int) -> Surface {
        var out = Surface(width: s.width, height: s.height, fill: bg)
        for y in 0..<s.height where y + dy < s.height {
            for x in 0..<s.width { out.set(x, y + dy, s.at(x, y)) }
        }
        return out
    }

    // MARK: - SESSION / WEEKLY gauge

    private static func gauge(into s: inout Surface, _ label: String, tier: String?,
                              percent: Double?, resetsAt: Date?, phase: Double) {
        background(&s)
        Clawd.draw(into: &s, originX: 2, originY: hover(phase), blink: blink(phase))
        PixelDraw.text(into: &s, label, x: 30, y: 2, color: orange)
        if let tier { PixelDraw.text(into: &s, tier, x: 30, y: 9, color: dim) }
        divider(&s, y: 18)

        guard let pct = percent else {
            PixelDraw.textCentered(into: &s, "NO PLAN DATA", y: 32, color: dim)
            PixelDraw.textCentered(into: &s, "OPEN USAGE APP", y: 42, color: dim)
            return
        }

        // Circular ring gauge (36px outer) with the percentage centered inside.
        let cx = s.width / 2, cy = 38
        ringGauge(&s, cx: cx, cy: cy, outerR: 18, thickness: 3, percent: pct)
        let pStr = "\(Int(pct.rounded()))%"
        let sc = PixelDraw.width(of: pStr, scale: 2) <= 28 ? 2 : 1
        PixelDraw.text(into: &s, pStr, x: cx - PixelDraw.width(of: pStr, scale: sc) / 2,
                       y: cy - (PixelDraw.fontHeight * sc) / 2, scale: sc, color: core, shadow: shadow)

        PixelDraw.textCentered(into: &s, "RESETS " + resetsIn(resetsAt), y: 58, color: bright)
    }

    /// A circular progress ring: a dim track with the used fraction swept clockwise from the top
    /// in an orange→bright gradient. Pure pixels (distance-thresholded, no anti-aliasing).
    private static func ringGauge(_ s: inout Surface, cx: Int, cy: Int,
                                  outerR: Double, thickness: Double, percent: Double) {
        let innerR = outerR - thickness
        let sweep = max(0, min(100, percent)) / 100 * (2 * Double.pi)
        let r = Int(outerR.rounded(.up))
        for dy in -r...r {
            for dx in -r...r {
                let dist = Double(dx * dx + dy * dy).squareRoot()
                if dist > outerR + 0.25 || dist < innerR - 0.25 { continue }
                var ang = atan2(Double(dx), Double(-dy))   // 0 at top, increasing clockwise
                if ang < 0 { ang += 2 * Double.pi }
                let c = ang <= sweep ? Palette.mix(orange, bright, ang / (2 * Double.pi)) : track
                s.set(cx + dx, cy + dy, c)
            }
        }
    }

    // MARK: - 7-DAY graph

    private static func graph(into s: inout Surface, _ u: ClaudeUsage, phase: Double, intro: Double) {
        background(&s)
        Clawd.draw(into: &s, originX: 2, originY: hover(phase), blink: blink(phase))
        PixelDraw.text(into: &s, "7 DAYS", x: 30, y: 3, color: orange)
        PixelDraw.text(into: &s, tokens(u.weekTokens), x: 30, y: 10, color: core)
        divider(&s, y: 18)
        guard u.last7.count == 7 else {   // no scan yet
            PixelDraw.textCentered(into: &s, "SCANNING", y: 40, color: dim)
            return
        }

        // Filled area / line chart of the 7 daily totals.
        let x0 = 4, x1 = s.width - 5
        let chartW = x1 - x0 + 1
        let baseY = 59, topY = 25
        let maxH = baseY - topY
        let maxTok = u.maxDayTokens

        let px = (0..<7).map { x0 + Int((Double($0) * Double(chartW - 1) / 6.0).rounded()) }
        let py = u.last7.map { baseY - Int((Double(maxH) * Double($0.tokens) / Double(maxTok) * intro).rounded()) }
        func lineY(_ x: Int) -> Int {
            var i = 0
            while i < 6 && px[i + 1] < x { i += 1 }
            let xa = px[i], xb = px[i + 1], ya = py[i], yb = py[i + 1]
            if xb == xa { return ya }
            return Int((Double(ya) + Double(x - xa) / Double(xb - xa) * Double(yb - ya)).rounded())
        }

        let fillTop = PixelRGB(red: 78, green: 44, blue: 30), fillBot = PixelRGB(red: 24, green: 14, blue: 11)
        for x in x0...x1 {                                   // area fill under the curve
            let ly = lineY(x)
            guard ly + 1 <= baseY else { continue }
            for y in (ly + 1)...baseY {
                let t = Double(y - ly) / Double(max(1, baseY - ly))
                s.set(x, y, Palette.mix(fillTop, fillBot, t))
            }
        }
        for gx in px {                                       // a faint vertical gridline per day
            for y in topY...baseY { s.set(gx, y, Palette.mix(s.at(gx, y), dim, 0.45)) }
        }
        var prevY: Int?
        for x in x0...x1 {                                   // the curve itself (continuous)
            let ly = lineY(x)
            let lo = min(prevY ?? ly, ly), hi = max(prevY ?? ly, ly)
            for y in lo...hi { s.set(x, y, bright) }
            prevY = ly
        }
        PixelDraw.fillRect(into: &s, x: x0, y: baseY + 1, w: chartW, h: 1, dim)   // baseline
    }

    // MARK: - 16×16 compact (Timebox)

    private static func compact(_ screen: Screen, _ u: ClaudeUsage, _ plan: ClaudePlan, phase: Double) -> Surface {
        var s = Surface(width: 16, height: 16, fill: bg)
        let label: String, value: String
        switch screen {
        case .session: label = "SESH"; value = plan.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .weekly:  label = "WEEK"; value = plan.weeklyPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        case .graph:   label = "7D";   value = tokensShort(u.weekTokens)
        }
        PixelDraw.textCentered(into: &s, label, y: 2, color: orange)
        PixelDraw.textCentered(into: &s, value, y: 9, color: core)
        return s
    }

    // MARK: - Shared chrome

    /// Flat background — no gradient (a radial glow quantizes into ugly bands under low-color
    /// display styles, and these data screens read cleaner flat anyway).
    private static func background(_ s: inout Surface) {
        for i in s.pixels.indices { s.pixels[i] = bg }
    }

    private static func divider(_ s: inout Surface, y: Int, color: PixelRGB = dim) {
        var x = 0
        while x < s.width { s.set(x, y, color); x += 2 }
    }

    // MARK: - Animation

    private static func blink(_ phase: Double) -> Bool { phase.truncatingRemainder(dividingBy: 3.6) < 0.16 }
    /// Downward-only hover, 0→2→0 px — never negative, so clawd's top row is never clipped.
    /// Driven by absolute time everywhere, so the motion is continuous across screen switches.
    private static func hover(_ phase: Double) -> Int { Int((1 - cos(phase * 1.5)).rounded()) }

    // MARK: - Formatting

    static func tokens(_ n: Int) -> String {
        let a = abs(n)
        func f(_ v: Double, _ suffix: String) -> String {
            v < 100 ? String(format: "%.1f%@", v, suffix) : "\(Int(v.rounded()))\(suffix)"
        }
        if a < 1_000 { return "\(n)" }
        if a < 1_000_000 { return f(Double(n) / 1_000, "K") }
        if a < 1_000_000_000 { return f(Double(n) / 1_000_000, "M") }
        return f(Double(n) / 1_000_000_000, "B")
    }

    static func tokensShort(_ n: Int) -> String {
        let a = abs(n)
        if a < 1_000 { return "\(n)" }
        if a < 1_000_000 { return "\(Int((Double(n) / 1_000).rounded()))K" }
        if a < 1_000_000_000 { return "\(Int((Double(n) / 1_000_000).rounded()))M" }
        return "\(Int((Double(n) / 1_000_000_000).rounded()))B"
    }
}
