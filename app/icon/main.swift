// doppel-appicon <output-directory>
//
// Draws Doppel's own app icon and writes a full iconset. The icon is generated
// rather than checked in as artwork: it is a handful of rounded rectangles, and
// a generator stays legible and adjustable where a binary blob does not. The
// same reasoning as the instance tinting — nothing here needs anything beyond
// what macOS already has.
//
// The mark is two offset tiles, the one behind showing past the one in front:
// a copy of something, which is the whole of what Doppel does. It has to read
// at 16 points, so it is two shapes and no detail.

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

func drawIcon(size: Int) -> CGImage {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a drawing context") }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS leaves a margin around the tile; the artwork does not run to the edge.
    let margin = side * 0.09
    let box = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)

    // The two tiles overlap on the diagonal. The back one peeks out at the top
    // left, the front one sits at the bottom right and carries the colour.
    // The offset has to survive a 16-point icon, where a thinner sliver of the
    // back tile turns into a smudge along the edge.
    let offset = box.width * 0.17
    let tileSide = box.width - offset
    let radius = tileSide * 0.235

    let back = Tile(rect: CGRect(x: box.minX, y: box.minY + offset,
                                 width: tileSide, height: tileSide), radius: radius)
    let front = Tile(rect: CGRect(x: box.minX + offset, y: box.minY,
                                  width: tileSide, height: tileSide), radius: radius)

    // Back tile: deeper and less bright than the front one. A pale tint reads
    // as a shadow and disappears on a light background; this has to hold its
    // own against white and against a dark Dock alike, so the separation
    // between the two is in tone rather than in opacity.
    context.saveGState()
    context.addPath(roundedPath(back))
    context.clip()
    context.drawLinearGradient(
        gradient([colour(104, 118, 224), colour(70, 82, 186)], [0, 1]),
        start: CGPoint(x: back.rect.minX, y: back.rect.maxY),
        end: CGPoint(x: back.rect.maxX, y: back.rect.minY),
        options: [])
    context.restoreGState()

    // A gap between the two tiles, so the front one stays a separate object and
    // does not merge into the back one wherever their tones happen to meet.
    // Everything inside the enlarged front shape is cleared; the front tile is
    // then drawn inside it, leaving a transparent ring of exactly this width.
    let gap = side * 0.02
    let seam = Tile(rect: front.rect.insetBy(dx: -gap, dy: -gap), radius: radius + gap)
    context.saveGState()
    context.addPath(roundedPath(seam))
    context.clip()
    context.setBlendMode(.clear)
    context.fill(box)
    context.restoreGState()

    // Front tile.
    context.saveGState()
    context.addPath(roundedPath(front))
    context.clip()
    context.drawLinearGradient(
        gradient([colour(140, 190, 255), colour(74, 130, 246)], [0, 1]),
        start: CGPoint(x: front.rect.minX, y: front.rect.maxY),
        end: CGPoint(x: front.rect.maxX, y: front.rect.minY),
        options: [])

    // A soft highlight along the top edge, which is what stops a flat gradient
    // reading as a sticker.
    context.drawLinearGradient(
        gradient([colour(255, 255, 255, 0.28), colour(255, 255, 255, 0)], [0, 1]),
        start: CGPoint(x: front.rect.midX, y: front.rect.maxY),
        end: CGPoint(x: front.rect.midX, y: front.rect.midY),
        options: [])
    context.restoreGState()

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
