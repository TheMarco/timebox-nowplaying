// Inspect an OTF/TTF and rasterize sample text at small pixel sizes (no anti-aliasing) to
// PNGs, so we can pick the crispest size for the LED ticker.
//   swiftc -O tools/FontPreview.swift -o /tmp/fontpreview && /tmp/fontpreview <font.otf> /tmp/preview
import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: fontpreview <font> [outdir]"); exit(1) }
let fontPath = args[1]
let outDir = args.count > 2 ? args[2] : "/tmp/preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let url = URL(fileURLWithPath: fontPath) as CFURL
var err: Unmanaged<CFError>?
CTFontManagerRegisterFontsForURL(url, .process, &err)
guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let desc = descs.first else {
    print("could not read font descriptors"); exit(1)
}
let probe = CTFontCreateWithFontDescriptor(desc, 16, nil)
print("PostScript name:", CTFontCopyPostScriptName(probe) as String)
print("Family:", CTFontCopyFamilyName(probe) as String)

func sample(_ text: String, pointSize: CGFloat) -> (cols: Int, rows: Int, png: String) {
    let font = CTFontCreateWithFontDescriptor(desc, pointSize, nil)
    let attr: [CFString: Any] = [kCTFontAttributeName: font,
                                 kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
    let astr = CFAttributedStringCreate(nil, text as CFString, attr as CFDictionary)!
    let line = CTLineCreateWithAttributedString(astr)
    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
    let w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let W = Int(w.rounded(.up)) + 4
    let H = Int((ascent + descent).rounded(.up)) + 2
    let bpr = W * 4
    var buf = [UInt8](repeating: 0, count: bpr * H)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(false)
    ctx.setAllowsAntialiasing(false)
    ctx.textPosition = CGPoint(x: 2, y: descent.rounded() + 1)
    CTLineDraw(line, ctx)
    // upscale ×6 nearest for viewing
    let scale = 6
    let uw = W * scale, uh = H * scale
    var ubuf = [UInt8](repeating: 0, count: uw * uh * 4)
    for y in 0..<uh { for x in 0..<uw {
        let o = (y*uw + x)*4, so = ((y/scale)*W + (x/scale))*4
        ubuf[o] = buf[so]; ubuf[o+1] = buf[so+1]; ubuf[o+2] = buf[so+2]; ubuf[o+3] = 255
    }}
    let uctx = CGContext(data: &ubuf, width: uw, height: uh, bitsPerComponent: 8, bytesPerRow: uw*4,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = uctx.makeImage()!
    let path = "\(outDir)/font_\(Int(pointSize)).png"
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    return (W, H, path)
}

let text = "DAFT PUNK - GET LUCKY 12:34"
for pt in [CGFloat(8), 10, 12, 14, 16, 20] {
    let r = sample(text, pointSize: pt)
    print("pt=\(Int(pt)): \(r.cols)x\(r.rows)px  -> \(r.png)")
}
