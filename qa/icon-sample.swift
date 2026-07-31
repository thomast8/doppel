// Reports the average colour of an icon's light, opaque pixels, so QA can
// assert a tint was actually applied instead of assuming it.
//
//   icon-sample <image.png>  ->  #RRGGBB
import CoreGraphics
import Foundation
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = 64, h = 64
var px = [UInt8](repeating: 0, count: w*h*4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
// Average the opaque, non-dark pixels: that is the tinted background.
var r = 0.0, g = 0.0, b = 0.0, n = 0.0
for i in stride(from: 0, to: px.count, by: 4) where px[i+3] > 200 {
    let lum = 0.2126*Double(px[i]) + 0.7152*Double(px[i+1]) + 0.0722*Double(px[i+2])
    if lum > 60 { r += Double(px[i]); g += Double(px[i+1]); b += Double(px[i+2]); n += 1 }
}
guard n > 0 else { print("no pixels"); exit(0) }
print(String(format: "#%02X%02X%02X", Int(r/n), Int(g/n), Int(b/n)))
