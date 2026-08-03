// doppel-appicon <output-directory>
//
// Draws Doppel's own app icon and writes a full iconset. The icon is generated
// rather than checked in as artwork: it is a handful of rounded rectangles, and
// a generator stays legible and adjustable where a binary blob does not. The
// same reasoning as the instance tinting — nothing here needs anything beyond
// what macOS already has.
//
// The mark is two offset speech-bubble loops: conversation plus duplication,
// expressed with Doppel's own asymmetric geometry. It deliberately avoids the
// rotational symmetry and interwoven knot construction of OpenAI's mark.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Tile {
    let rect: CGRect
    let radius: CGFloat
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("doppel-appicon: \(message)\n".utf8))
    exit(1)
}

/// A rounded rectangle in the shape macOS uses for app tiles.
func roundedPath(_ tile: Tile) -> CGPath {
    CGPath(roundedRect: tile.rect, cornerWidth: tile.radius, cornerHeight: tile.radius,
           transform: nil)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let result = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: colors as CFArray, locations: locations)
    else { fail("could not build a gradient") }
    return result
}

func colour(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a drawing context") }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

/// A rounded conversation bubble whose lower-left tail is part of the contour,
/// so the same path works as a filled shape or a clean continuous outline.
func bubblePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let tailHeight = rect.height * 0.20
    let bodyBottom = rect.minY + tailHeight
    let radius = min(rect.width * 0.16, (rect.height - tailHeight) * 0.30)
    let tailStart = rect.minX + rect.width * 0.22
    let tailTip = CGPoint(x: rect.minX + rect.width * 0.09, y: rect.minY)
    let tailEnd = rect.minX + rect.width * 0.41

    path.move(to: CGPoint(x: rect.minX + radius, y: bodyBottom))
    path.addLine(to: CGPoint(x: tailStart, y: bodyBottom))
    path.addQuadCurve(to: tailTip,
                      control: CGPoint(x: tailStart - rect.width * 0.035,
                                       y: bodyBottom - tailHeight * 0.48))
    path.addQuadCurve(to: CGPoint(x: tailEnd, y: bodyBottom),
                      control: CGPoint(x: tailTip.x + rect.width * 0.16,
                                       y: tailTip.y + tailHeight * 0.36))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: bodyBottom))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bodyBottom + radius),
                      control: CGPoint(x: rect.maxX, y: bodyBottom))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                      control: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                      control: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom + radius))
    path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: bodyBottom),
                      control: CGPoint(x: rect.minX, y: bodyBottom))
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let side = CGFloat(size)
    let context = makeContext(size: size)

    // One macOS tile gives the original mark a stable silhouette in Finder and
    // the Dock. The paired bubbles carry duplication within it.
    let margin = side * 0.075
    let tile = Tile(rect: CGRect(x: margin, y: margin,
                                 width: side - margin * 2, height: side - margin * 2),
                    radius: side * 0.205)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.025),
                      blur: side * 0.055, color: colour(16, 20, 54, 0.44))
    context.addPath(roundedPath(tile))
    context.setFillColor(colour(42, 48, 112))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedPath(tile))
    context.clip()
    context.drawLinearGradient(
        gradient([colour(116, 129, 255), colour(61, 70, 173), colour(32, 37, 91)],
                 [0, 0.48, 1]),
        start: CGPoint(x: tile.rect.minX, y: tile.rect.maxY),
        end: CGPoint(x: tile.rect.maxX, y: tile.rect.minY),
        options: [])
    context.drawLinearGradient(
        gradient([colour(255, 255, 255, 0.24), colour(255, 255, 255, 0)], [0, 1]),
        start: CGPoint(x: tile.rect.midX, y: tile.rect.maxY),
        end: CGPoint(x: tile.rect.midX, y: tile.rect.midY),
        options: [])
    context.restoreGState()

    let back = bubblePath(in: CGRect(x: side * 0.15, y: side * 0.38,
                                     width: side * 0.56, height: side * 0.42))
    let front = bubblePath(in: CGRect(x: side * 0.29, y: side * 0.20,
                                      width: side * 0.56, height: side * 0.42))

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // The receding bubble is lavender and slightly quieter. A soft shadow keeps
    // its outline legible against both ends of the background gradient.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                      blur: side * 0.02, color: colour(18, 20, 64, 0.42))
    context.addPath(back)
    context.setStrokeColor(colour(187, 194, 255, 0.82))
    context.setLineWidth(side * 0.055)
    context.strokePath()
    context.restoreGState()

    // A wider background-coloured stroke first creates a seam, making the front
    // bubble visibly pass over the back one rather than merging into it.
    context.addPath(front)
    context.setStrokeColor(colour(49, 56, 139, 0.96))
    context.setLineWidth(side * 0.086)
    context.strokePath()
    context.addPath(front)
    context.setStrokeColor(colour(246, 248, 255))
    context.setLineWidth(side * 0.055)
    context.strokePath()

    // A hairline on the outer tile keeps the edge crisp on similarly coloured
    // wallpapers without turning it into another nested square.
    context.addPath(roundedPath(tile))
    context.setStrokeColor(colour(255, 255, 255, 0.18))
    context.setLineWidth(max(1, side * 0.006))
    context.strokePath()

    guard let image = context.makeImage() else { fail("could not render the icon") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not write to \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finalise \(url.path)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fail("usage: doppel-appicon <output-directory>") }
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    write(drawIcon(size: size),
          to: outputDirectory.appendingPathComponent("icon_\(size)x\(size).png"))
    write(drawIcon(size: size * 2),
          to: outputDirectory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(outputDirectory.path)
