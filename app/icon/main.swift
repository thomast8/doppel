// doppel-appicon <output-directory>
//
// Draws Doppel's own app icon and writes a full iconset. The icon is generated
// rather than checked in as artwork: it is a handful of rounded rectangles, and
// a generator stays legible and adjustable where a binary blob does not. The
// same reasoning as the instance tinting — nothing here needs anything beyond
// what macOS already has.
//
// The mark is the picture the app itself opens on: instances fanned out like
// cards on a dark slab, each glowing in its own colour, the front one carrying
// a speech bubble, and above them a light per instance as the menu bar panel
// shows them. It deliberately avoids the rotational symmetry and interwoven
// knot construction of OpenAI's mark.

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

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    roundedPath(Tile(rect: rect, radius: radius))
}

/// The dark slab every Doppel page opens on, on Apple's icon grid.
func drawSlab(_ context: CGContext, side: CGFloat) -> CGRect {
    let margin = side * 0.0977
    let rect = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let radius = side * 0.181
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 0.02), blur: side * 0.045,
                      color: colour(0, 0, 0, 0.5))
    context.addPath(roundedPath(rect, radius: radius))
    context.setFillColor(colour(20, 20, 22))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedPath(rect, radius: radius))
    context.clip()
    context.drawLinearGradient(
        gradient([colour(44, 44, 48), colour(22, 22, 25), colour(10, 10, 12)], [0, 0.5, 1]),
        start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [])
    context.restoreGState()

    // A hairline keeps the edge visible on a dark Dock or wallpaper.
    context.addPath(roundedPath(rect.insetBy(dx: side * 0.002, dy: side * 0.002), radius: radius))
    context.setStrokeColor(colour(255, 255, 255, 0.10))
    context.setLineWidth(max(1, side * 0.004))
    context.strokePath()
    return rect
}

struct Hue {
    let top: CGColor
    let bottom: CGColor
    let glow: CGColor
}

let purple = Hue(top: colour(196, 140, 255), bottom: colour(134, 66, 232), glow: colour(150, 80, 255, 0.75))
let blue = Hue(top: colour(120, 170, 255), bottom: colour(54, 110, 240), glow: colour(70, 130, 255, 0.85))
let orange = Hue(top: colour(255, 190, 110), bottom: colour(232, 126, 40), glow: colour(255, 140, 40, 0.75))

/// One instance: a rounded tile in its colour, glowing, turned about its
/// centre.
func drawInstance(_ context: CGContext, center: CGPoint, size: CGFloat, angle: CGFloat,
                  hue: Hue, side: CGFloat, bubble: Bool = false) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle * .pi / 180)
    let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    let radius = size * 0.24

    context.saveGState()
    context.setShadow(offset: .zero, blur: side * 0.07, color: hue.glow)
    context.addPath(roundedPath(rect, radius: radius))
    context.setFillColor(hue.bottom)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedPath(rect, radius: radius))
    context.clip()
    context.drawLinearGradient(gradient([hue.top, hue.bottom], [0, 1]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY),
                               options: [])
    context.drawLinearGradient(
        gradient([colour(255, 255, 255, 0.28), colour(255, 255, 255, 0)], [0, 1]),
        start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: 0), options: [])
    context.restoreGState()

    context.addPath(roundedPath(rect.insetBy(dx: size * 0.01, dy: size * 0.01), radius: radius))
    context.setStrokeColor(colour(255, 255, 255, 0.22))
    context.setLineWidth(max(1, size * 0.02))
    context.strokePath()

    if bubble {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.04,
                          color: colour(0, 0, 0, 0.25))
        context.addPath(bubblePath(in: CGRect(x: -size * 0.27, y: -size * 0.25,
                                              width: size * 0.54, height: size * 0.46)))
        context.setFillColor(colour(255, 255, 255))
        context.fillPath()
        context.restoreGState()
    }
    context.restoreGState()
}

func drawIcon(size: Int) -> CGImage {
    let side = CGFloat(size)
    let context = makeContext(size: size)
    let slab = drawSlab(context, side: side)
    let tile = side * 0.385
    let y = slab.midY - side * 0.04

    drawInstance(context, center: CGPoint(x: slab.midX - side * 0.185, y: y - side * 0.01),
                 size: tile * 0.88, angle: 13, hue: purple, side: side)
    drawInstance(context, center: CGPoint(x: slab.midX + side * 0.185, y: y - side * 0.01),
                 size: tile * 0.88, angle: -13, hue: orange, side: side)
    drawInstance(context, center: CGPoint(x: slab.midX, y: y + side * 0.02),
                 size: tile, angle: 0, hue: blue, side: side, bubble: true)

    // The panel's lights, one per instance, in the same order.
    let dot = side * 0.032
    let gap = side * 0.058
    for (index, hue) in [purple, blue, orange].enumerated() {
        let x = slab.midX + CGFloat(index - 1) * gap
        context.saveGState()
        context.setShadow(offset: .zero, blur: side * 0.025, color: hue.bottom)
        context.addEllipse(in: CGRect(x: x - dot / 2, y: slab.maxY - side * 0.135, width: dot, height: dot))
        context.setFillColor(hue.bottom)
        context.fillPath()
        context.restoreGState()
    }

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
