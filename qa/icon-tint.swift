import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
precondition(args.count == 6)
let helper = args[1], legacy = args[2]
let root = URL(fileURLWithPath: args[3], isDirectory: true)
let claude = URL(fileURLWithPath: args[4]), chatgpt = URL(fileURLWithPath: args[5])

func read(_ url: URL) -> (CGImage, [UInt8]) {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &pixels, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image, pixels)
}

func write(_ pixels: [UInt8], to url: URL) {
    let data = Data(pixels) as CFData
    let image = CGImage(width: pixels.count / 4, height: 1, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: pixels.count,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output))
}

func tint(_ source: URL, _ name: String, _ hex: String, app: String? = "claude", tool: String? = nil) -> URL {
    let output = root.appendingPathComponent(name + ".png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool ?? helper)
    process.arguments = [source.path, output.path, hex] + (app.map { [$0] } ?? [])
    try! process.run(); process.waitUntilExit()
    precondition(process.terminationStatus == 0)
    return output
}

let fixture = root.appendingPathComponent("fixture.png")
let original: [UInt8] = [220,120,90,255, 248,242,235,255, 0,0,0,0, 0,0,0,80, 245,245,245,255, 20,20,20,255]
write(original, to: fixture)
let blue = read(tint(fixture, "fixture-blue", "3B82F6")).1
precondition(Array(blue[4..<16]) == Array(original[4..<16]), "Claude's glyph, transparent exterior and shadow must survive")
precondition(blue[2] > blue[1] && blue[1] > blue[0], "Claude's tile must become blue")
let light = read(tint(fixture, "fixture-light", "FFFFFF")).1
precondition(light[0] < 160 && light[4] > 230, "Light tints must retain glyph contrast")
for color in ["F28C28", "3B82F6", "FFFFFF", "000000"] {
    let old = read(tint(chatgpt, "legacy-" + color, color, app: nil, tool: legacy)).1
    let current = read(tint(chatgpt, "chatgpt-" + color, color, app: "chatgpt")).1
    precondition(old == current, "ChatGPT pixels changed for " + color)
}

let source = read(claude)
var variants: [(String, URL)] = [("Original", claude)]
for (name, color) in [("Orange", "F28C28"), ("Blue", "3B82F6"), ("Purple", "A855F7"), ("Graphite", "64748B"), ("White", "FFFFFF")] {
    let output = tint(claude, name.lowercased(), color)
    let result = read(output).1
    let center = (source.0.height / 2 * source.0.width + source.0.width / 2) * 4
    precondition(Array(result[center..<center+4]) == Array(source.1[center..<center+4]), "The real Claude star changed")
    precondition(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == source.1[$0] }, "Icon transparency changed")
    variants.append((name, output))
}

let preview = NSImage(size: NSSize(width: 720, height: 240))
preview.lockFocus()
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 720, height: 240).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
for (index, variant) in variants.enumerated() {
    let x = CGFloat(index * 120)
    let icon = NSImage(contentsOf: variant.1)!
    icon.draw(in: NSRect(x: x + 12, y: 105, width: 96, height: 96))
    icon.draw(in: NSRect(x: x + 44, y: 40, width: 32, height: 32))
    (variant.0 as NSString).draw(at: NSPoint(x: x + 28, y: 214), withAttributes: attributes)
}
("96 px / 32 px" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: attributes)
preview.unlockFocus()
let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("preview.png"))
print("Icon QA passed: Claude glyph/alpha/contrast, real icon variants, and exact ChatGPT compatibility for four tints")
print(root.appendingPathComponent("preview.png").path)
