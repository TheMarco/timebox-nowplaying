import Foundation
import TimeboxKit

/// Boosts saturation and contrast so downscaled album art reads better on an LED panel.
enum ImageEnhance {
    static func punchUp(_ surface: Surface, saturation: Double = 1.5, contrast: Double = 1.18) -> Surface {
        let pixels = surface.pixels.map { pixel -> PixelRGB in
            var r = Double(pixel.red) / 255.0
            var g = Double(pixel.green) / 255.0
            var b = Double(pixel.blue) / 255.0

            // Contrast around mid-gray.
            func contrasted(_ v: Double) -> Double { (v - 0.5) * contrast + 0.5 }
            r = contrasted(r); g = contrasted(g); b = contrasted(b)

            // Saturation: push each channel away from luma.
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            r = luma + (r - luma) * saturation
            g = luma + (g - luma) * saturation
            b = luma + (b - luma) * saturation

            func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            return PixelRGB(red: byte(r), green: byte(g), blue: byte(b))
        }
        return Surface(width: surface.width, height: surface.height, pixels: pixels) ?? surface
    }
}
