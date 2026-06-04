import Foundation
import TimeboxKit

/// Digital clock: 12-hour "H:MM" pinned to the top with a flashing red colon, and a
/// scrolling "Artist — Title" ticker (5px pixel font) below it. The time uses a small
/// 3x5 digit font; the ticker uses `PixelFont`.
enum DigitalClockRenderer {
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

    private static let timeTopY = 2   // time occupies rows 2...6
    private static let tickerTopY = 9 // 5px ticker occupies rows 9...13

    static func frame(for date: Date, ticker: String = "", scroll: Int = 0,
                      calendar: Calendar = .current, use24Hour: Bool = false) -> PixelFrame {
        var grid = [PixelRGB](repeating: PixelRGB(red: 0, green: 0, blue: 0), count: 256)
        func set(_ x: Int, _ y: Int, _ color: PixelRGB) {
            guard x >= 0, x < 16, y >= 0, y < 16 else { return }
            grid[y * 16 + x] = color
        }

        let white = PixelRGB(red: 255, green: 255, blue: 255)
        let red = PixelRGB(red: 255, green: 40, blue: 40)
        let tickerColor = PixelRGB(red: 120, green: 170, blue: 255)

        // --- Time, pinned to the top (12-hour, no leading zero, no AM/PM) ---
        func drawDigit(_ value: Int, atX originX: Int) {
            guard (0...9).contains(value) else { return }
            for (rowIndex, row) in glyphs[value].enumerated() {
                for (colIndex, char) in row.enumerated() where char == "#" {
                    set(originX + colIndex, timeTopY + rowIndex, white)
                }
            }
        }
        func glyphWidth(_ value: Int) -> Int { glyphs[value].first?.count ?? 3 }

        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        var hour = comps.hour ?? 0
        if !use24Hour { hour %= 12; if hour == 0 { hour = 12 } }
        let minute = comps.minute ?? 0
        let h1 = hour / 10, h2 = hour % 10, m1 = minute / 10, m2 = minute % 10

        // Tokens: digit values, or -1 for the colon. Drop a leading-zero hour in 12h.
        var tokens: [Int] = []
        if use24Hour || h1 != 0 { tokens.append(h1) }
        tokens.append(h2); tokens.append(-1); tokens.append(m1); tokens.append(m2)
        let colonWidth = 1
        func tokenWidth(_ t: Int) -> Int { t == -1 ? colonWidth : glyphWidth(t) }

        let widthSum = tokens.map(tokenWidth).reduce(0, +)
        let gap = (widthSum + (tokens.count - 1)) > 16 ? 0 : 1
        let totalW = widthSum + gap * (tokens.count - 1)

        var x = max(0, (16 - totalW + 1) / 2)
        for (i, t) in tokens.enumerated() {
            if t == -1 {
                if (comps.second ?? 0) % 2 == 0 {       // flash once per second
                    set(x, timeTopY + 1, red)
                    set(x, timeTopY + 3, red)
                }
            } else {
                drawDigit(t, atX: x)
            }
            x += tokenWidth(t) + (i < tokens.count - 1 ? gap : 0)
        }

        // --- Ticker below: single left-to-right pass. Scrolls in from the right edge
        // and slides off the left as `scroll` grows; the controller ends the pass once
        // it's fully gone, then crossfades to the next view. ---
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            for (i, col) in PixelFont.columns(for: text).enumerated() {
                let screenX = i - scroll + 16     // start off the right edge, scroll in
                guard screenX >= 0, screenX < 16 else { continue }
                for y in 0..<PixelFont.height where col[y] { set(screenX, tickerTopY + y, tickerColor) }
            }
        }

        return (try? PixelFrame(pixels: grid)) ?? PixelFrame()
    }
}
