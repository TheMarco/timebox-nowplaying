import SwiftUI
import TimeboxKit

/// A live view of the `SimulatorScreen` as a real Divoom-style LED matrix: 64×64 discrete square
/// pixels with a 1px dark gap between them (the panel's black mesh). Integer-aligned, sharp squares
/// — no rounding, no anti-aliasing — with the panel brightness applied.
struct PixooSimulatorView: View {
    @ObservedObject var screen: SimulatorScreen

    var body: some View {
        Canvas { ctx, size in
            let n = 64
            guard screen.frame.width == n, screen.frame.height == n else { return }
            let cell = max(2, floor(min(size.width, size.height) / CGFloat(n)))
            let gap: CGFloat = cell >= 5 ? 1 : 0          // dark separator between pixels
            let sq = cell - gap
            let total = cell * CGFloat(n)
            let ox = floor((size.width - total) / 2)
            let oy = floor((size.height - total) / 2)
            let b = screen.brightness

            // Black base shows through the gaps as the LED mesh.
            ctx.fill(Path(CGRect(x: ox, y: oy, width: total, height: total)), with: .color(.black))

            for y in 0..<n {
                for x in 0..<n {
                    let p = screen.frame.at(x, y)
                    let r = Double(p.red) / 255 * b
                    let g = Double(p.green) / 255 * b
                    let bl = Double(p.blue) / 255 * b
                    let rect = CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell,
                                      width: sq, height: sq)
                    ctx.fill(Path(rect), with: .color(Color(red: r, green: g, blue: bl)))
                }
            }
        }
        .frame(minWidth: 320, minHeight: 320)
        .background(Color.black)
    }
}
