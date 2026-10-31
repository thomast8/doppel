// doppel-icon <source.png> <output.png> <RRGGBB> [chatgpt|claude]
//
// Tints each app's background while preserving its glyph and transparent exterior.
//
// This exists so Doppel needs nothing beyond macOS itself. The same filter used
// to run through Python and Pillow, fetched on demand by uv — a package manager
// dependency for one pixel loop, and one that a GUI app could not even reach,
// since a launchd-started process does not inherit a PATH containing it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("doppel-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
let catalogMode = arguments.count == 5 && arguments[1] == "--catalog"
guard catalogMode || arguments.count == 4 || arguments.count == 5 else {
    fail("usage: doppel-icon <source.png> <output.png> <RRGGBB> [chatgpt|claude]\n"
        + "       doppel-icon --catalog <source Assets.car> <output Assets.car> <RRGGBB>")
}
let app = catalogMode ? "claude" : arguments.count == 5 ? arguments[4] : "chatgpt"
guard app == "chatgpt" || app == "claude" else { fail("unsupported app: \(app)") }
let sourceURL = URL(fileURLWithPath: arguments[catalogMode ? 2 : 1])
let outputURL = URL(fileURLWithPath: arguments[catalogMode ? 3 : 2])

let hex = arguments[catalogMode ? 4 : 3].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
    fail("the tint must be six hex digits, for example F28C28")
}
let tint = (
    r: Double((rgb >> 16) & 0xFF),
    g: Double((rgb >> 8) & 0xFF),
    b: Double(rgb & 0xFF)
)
// Claude has a pale glyph on a coloured tile. Keep light tints dark enough to read it.
let tintLuminance = 0.2126 * tint.r + 0.7152 * tint.g + 0.0722 * tint.b
let tintScale = app == "claude" ? min(1, 150 / max(tintLuminance, 1)) : 1

// Claude ships its icon as an Icon Composer asset catalog, the only icon form
// macOS redraws for dark mode and the clear and tinted styles; a flat .icns
// looks the same in all of them. Its accent is one gradient of Display P3
// colours: the tile in light mode, the star in dark mode. Recolouring just
// those records, in place and at the same size, keeps every variant the vendor
// designed. Neutral colours, the pale star and the dark tile, stay as they are.
//
// A colour record is "RLOC", a version, a colour space, a component count and
// that many little-endian doubles. Exiting non-zero when there is no accent to
// recolour lets the engine fall back to the flat icon.
if catalogMode {
    guard var bytes = FileManager.default.contents(atPath: sourceURL.path).map([UInt8].init) else {
        fail("could not read \(sourceURL.path)")
    }
    let displayP3: UInt32 = 3
    let tag = Array("RLOC".utf8)
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    func word(_ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    func double(_ offset: Int) -> Double {
        Double(bitPattern: bytes[offset..<offset + 8].enumerated()
            .reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
    }
    func store(_ value: Double, at offset: Int) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.replaceSubrange(offset..<offset + 8, with: $0) }
    }

    var recoloured = 0
    var offset = 0
    while offset + 48 <= bytes.count {
        defer { offset += 1 }
        guard bytes[offset] == tag[0], Array(bytes[offset..<offset + 4]) == tag,
              word(offset + 4) == 1, word(offset + 8) == displayP3, word(offset + 12) == 4
        else { continue }
        let start = offset + 16
        let colour = (0..<3).map { double(start + $0 * 8) }
        guard let maximum = colour.max(), let minimum = colour.min(), maximum > 0,
              (maximum - minimum) / maximum > 0.2
        else { continue }
        // The pixel filter's shading: keep the vendor's brightness, scaled down for light tints.
        let shade = maximum * tintScale
        let srgb = CGColor(srgbRed: tint.r / 255 * shade, green: tint.g / 255 * shade,
                           blue: tint.b / 255 * shade, alpha: 1)
        guard let converted = srgb.converted(to: p3, intent: .defaultIntent, options: nil)?.components else {
            fail("could not convert the tint to Display P3")
        }
        for index in 0..<3 { store(min(max(Double(converted[index]), 0), 1), at: start + index * 8) }
        recoloured += 1
        offset += 47
    }
    guard recoloured > 0 else { fail("no accent colour to recolour in \(sourceURL.path)") }
    guard FileManager.default.createFile(atPath: outputURL.path, contents: Data(bytes)) else {
        fail("could not write \(outputURL.path)")
    }
    exit(0)
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("could not read \(sourceURL.path)")
}

let width = image.width
let height = image.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("could not create a drawing context")
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

for index in stride(from: 0, to: pixels.count, by: 4) {
    let alpha = Double(pixels[index + 3])
    guard alpha > 0 else { continue }

    // CoreGraphics gives premultiplied components; the filter is defined on
    // straight colour, so undo the multiply and restore it afterwards.
    let scale = 255.0 / alpha
    var red = Double(pixels[index]) * scale
    var green = Double(pixels[index + 1]) * scale
    var blue = Double(pixels[index + 2]) * scale

    let maximum = max(red, green, blue)
    let minimum = min(red, green, blue)
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

    // Select the neutral, light background and its shadows. Dark glyph pixels
    // and saturated bevels score near zero and pass through unchanged.
    let neutrality = 1.0 - ((maximum - minimum) / max(maximum, 1))
    let lightWeight = clamp((luminance - 118.0) / 82.0)
    let neutralWeight = clamp((neutrality - 0.72) / 0.24)
    let weight: Double
    let shade: Double
    if app == "claude" {
        // Select the coloured tile, preserving the pale star and neutral exterior shadows.
        weight = clamp((1 - neutrality - 0.12) / 0.20)
            * (1 - clamp((luminance - 210) / 25))
        shade = maximum / 255.0 * tintScale
    } else {
        weight = lightWeight * neutralWeight
        shade = luminance / 255.0
    }
    guard weight > 0 else { continue }

    red = red * (1 - weight) + tint.r * shade * weight
    green = green * (1 - weight) + tint.g * shade * weight
    blue = blue * (1 - weight) + tint.b * shade * weight

    let premultiply = alpha / 255.0
    pixels[index] = UInt8(clamping: Int((red * premultiply).rounded()))
    pixels[index + 1] = UInt8(clamping: Int((green * premultiply).rounded()))
    pixels[index + 2] = UInt8(clamping: Int((blue * premultiply).rounded()))
}

guard let tinted = context.makeImage() else {
    fail("could not render the tinted image")
}

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    fail("could not write to \(outputURL.path)")
}
CGImageDestinationAddImage(destination, tinted, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("could not finalise \(outputURL.path)")
}
