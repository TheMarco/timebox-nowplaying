import Foundation
import TimeboxKit

/// "Clawd" — the Claude pixel mascot, traced cell-for-cell from the reference (`clawd.png`).
/// He is ALWAYS drawn at his native 24×15, one device pixel per sprite cell — never scaled up or
/// down (that distorts him). Pure flat pixels: one body color, plain black eye-slits, full-width
/// arm band, four toes. No shading, no outline, no anti-aliasing.
enum Clawd {
    /// Body color, sampled from the reference.
    static let terracotta = PixelRGB(red: 204, green: 120, blue: 92)
    /// Eye color, sampled from the reference (essentially black).
    static let eyeColor = PixelRGB(red: 0, green: 0, blue: 4)

    static let width = 24
    static let height = 15
    private static let eyeMidRow = 4   // the row a blink collapses the slit to

    // '#' = body, 'o' = eye, '.' = background. Exactly 24×15.
    private static let pixels: [String] = [
        "...##################...",   // 0
        "...##################...",   // 1
        "...##################...",   // 2
        "...###o##########o###...",   // 3  eyes (1px slits at cols 6 & 17)
        "...###o##########o###...",   // 4
        "...###o##########o###...",   // 5
        "########################",   // 6  arms: full-width band
        "########################",   // 7
        "########################",   // 8
        "...##################...",   // 9
        "...##################...",   // 10
        "...##################...",   // 11
        "....##.##......##.##....",   // 12  four toes
        "....##.##......##.##....",   // 13
        "....##.##......##.##....",   // 14
    ]
    private static let grid = pixels.map(Array.init)

    /// Draw clawd at his native 24×15 with top-left at (`originX`,`originY`). `base` recolors the
    /// body; `blink` shuts the eyes for a frame.
    static func draw(into s: inout Surface, originX: Int, originY: Int,
                     base: PixelRGB = terracotta, blink: Bool = false) {
        for y in 0..<height {
            for x in 0..<width {
                switch grid[y][x] {
                case ".": continue
                case "o": s.set(originX + x, originY + y, blink ? (y == eyeMidRow ? eyeColor : base) : eyeColor)
                default:  s.set(originX + x, originY + y, base)
                }
            }
        }
    }
}
