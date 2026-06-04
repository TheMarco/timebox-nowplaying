import Foundation
import TimeboxKit

/// Renders a digital clock "HH:MM" on a single line with a hand-drawn pixel
/// font (proportional width — "1" is 1px), and a red colon that flashes once
/// per second. Drawn directly onto the 16x16 grid so it's pixel-crisp.
enum DigitalClockRenderer {
    static var isAvailable: Bool { true }

    // Variable-width glyphs (5 tall). "1" is 1px wide; the rest are 3px.
    private static let glyphs: [[String]] = [
        ["###", "#.#", "#.#", "#.#", "###"], // 0
        ["#", "#", "#", "#", "#"],           // 1  (1px wide)
        ["###", "..#", "###", "#..", "###"], // 2
        ["###", "..#", "###", "..#", "###"], // 3
        ["#.#", "#.#", "###", "..#", "..#"], // 4
        ["###", "#..", "###", "..#", "###"], // 5
        ["###", "#..", "###", "#.#", "###"], // 6
        ["###", "..#", "..#", "..#", "..#"], // 7
        ["###", "#.#", "###", "#.#", "###"], // 8
        ["###", "#.#", "###", "..#", "###"]  // 9
    ]

    private static let topY = 5 // digits occupy rows 5...9

    static func frame(for date: Date, calendar: Calendar = .current, use24Hour: Bool = true) -> PixelFrame {
        var grid = [PixelRGB](repeating: PixelRGB(red: 0, green: 0, blue: 0), count: 256)
        func set(_ x: Int, _ y: Int, _ color: PixelRGB) {
            guard x >= 0, x < 16, y >= 0, y < 16 else { return }
            grid[y * 16 + x] = color
        }
        func drawDigit(_ value: Int, atX originX: Int, _ color: PixelRGB) {
            guard (0...9).contains(value) else { return }
            for (rowIndex, row) in glyphs[value].enumerated() {
                for (colIndex, char) in row.enumerated() where char == "#" {
                    set(originX + colIndex, topY + rowIndex, color)
                }
            }
        }
        func glyphWidth(_ value: Int) -> Int { glyphs[value].first?.count ?? 3 }

        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        var hour = comps.hour ?? 0
        if !use24Hour { hour %= 12; if hour == 0 { hour = 12 } }
        let minute = comps.minute ?? 0
        let h1 = hour / 10, h2 = hour % 10, m1 = minute / 10, m2 = minute % 10
        let colonWidth = 1

        let contentWidth = glyphWidth(h1) + glyphWidth(h2) + colonWidth + glyphWidth(m1) + glyphWidth(m2)
        // Gaps between [H1 H2 : M1 M2]; close the inner pairs first if it'd overflow.
        var gaps = [1, 1, 1, 1]
        func total() -> Int { contentWidth + gaps.reduce(0, +) }
        if total() > 16 { gaps[0] = 0; gaps[3] = 0 }
        if total() > 16 { gaps[1] = 0; gaps[2] = 0 }

        let white = PixelRGB(red: 255, green: 255, blue: 255)
        let red = PixelRGB(red: 255, green: 40, blue: 40)

        var x = max(0, (16 - total() + 1) / 2)
        drawDigit(h1, atX: x, white); x += glyphWidth(h1) + gaps[0]
        drawDigit(h2, atX: x, white); x += glyphWidth(h2) + gaps[1]
        if ((comps.second ?? 0) % 2 == 0) {           // flash once per second
            set(x, topY + 1, red)
            set(x, topY + 3, red)
        }
        x += colonWidth + gaps[2]
        drawDigit(m1, atX: x, white); x += glyphWidth(m1) + gaps[3]
        drawDigit(m2, atX: x, white)

        return (try? PixelFrame(pixels: grid)) ?? PixelFrame()
    }
}
