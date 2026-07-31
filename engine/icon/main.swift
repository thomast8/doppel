// doppel-icon <source.png> <output.png> <RRGGBB>
//
// Tints the neutral, light background of an app icon while leaving the glyph,
// the coloured bevels and the transparent exterior untouched.
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
guard arguments.count == 4 else {
    fail("usage: doppel-icon <source.png> <output.png> <RRGGBB>")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

let hex = arguments[3].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
    fail("the tint must be six hex digits, for example F28C28")
}
let tint = (
    r: Double((rgb >> 16) & 0xFF),
    g: Double((rgb >> 8) & 0xFF),
    b: Double(rgb & 0xFF)
)

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
    let weight = lightWeight * neutralWeight
    guard weight > 0 else { continue }

    let shade = luminance / 255.0
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
