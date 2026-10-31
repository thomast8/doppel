import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
precondition(args.count == 7)
let helper = args[1], legacy = args[2]
let root = URL(fileURLWithPath: args[3], isDirectory: true)
let claude = URL(fileURLWithPath: args[4]), chatgpt = URL(fileURLWithPath: args[5])
let claudeCatalog = URL(fileURLWithPath: args[6])

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

// An asset catalog colour record: "RLOC", version, colour space, component count, doubles.
func colorRecord(_ space: UInt32, _ components: [Double]) -> [UInt8] {
    var bytes = Array("RLOC".utf8)
    for word in [1, space, UInt32(components.count)] { withUnsafeBytes(of: word.littleEndian) { bytes += $0 } }
    for value in components { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes += $0 } }
    return bytes
}

func components(_ bytes: [UInt8], at offset: Int, count: Int) -> [Double] {
    (0..<count).map { index in
        Double(bitPattern: bytes[(offset + 16 + index * 8)..<(offset + 24 + index * 8)]
            .enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
    }
}

func recolor(_ source: URL, _ name: String, _ hex: String) -> (status: Int32, output: URL) {
    let output = root.appendingPathComponent(name + ".car")
    try? FileManager.default.removeItem(at: output)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    process.arguments = ["--catalog", source.path, output.path, hex]
    try! process.run(); process.waitUntilExit()
    return (process.terminationStatus, output)
}

// The accent is recoloured; the pale star (grey) and the dark tile (neutral P3) are not.
let padding = [UInt8](repeating: 7, count: 32)
let accent = colorRecord(3, [0.851, 0.467, 0.341, 1])
let star = colorRecord(2, [1, 1])
let darkTile = colorRecord(3, [0.08, 0.08, 0.08, 1])
let catalogBytes = padding + accent + padding + star + darkTile + padding
let catalogFixture = root.appendingPathComponent("fixture.car")
try! Data(catalogBytes).write(to: catalogFixture)
let blueCatalog = recolor(catalogFixture, "fixture-blue", "3B82F6")
precondition(blueCatalog.status == 0, "Recolouring a catalog with an accent must succeed")
let blueBytes = [UInt8](try! Data(contentsOf: blueCatalog.output))
precondition(blueBytes.count == catalogBytes.count, "Recolouring must not change the catalog's size")
let accentOffset = padding.count
precondition(Array(blueBytes[0..<(accentOffset + 16)]) == Array(catalogBytes[0..<(accentOffset + 16)]), "Bytes before the accent components changed")
precondition(Array(blueBytes[(accentOffset + accent.count - 8)...]) == Array(catalogBytes[(accentOffset + accent.count - 8)...]), "The star, the dark tile or the accent's alpha changed")
let blueAccent = components(blueBytes, at: accentOffset, count: 4)
precondition(blueAccent[2] > blueAccent[1] && blueAccent[1] > blueAccent[0], "The accent must become blue")
let whiteCatalog = recolor(catalogFixture, "fixture-white", "FFFFFF")
let whiteAccent = components([UInt8](try! Data(contentsOf: whiteCatalog.output)), at: accentOffset, count: 4)
precondition(whiteAccent[0] < 0.65, "Light tints must stay dark enough for the pale star")
let neutralFixture = root.appendingPathComponent("neutral.car")
try! Data(padding + star + darkTile).write(to: neutralFixture)
precondition(recolor(neutralFixture, "neutral-blue", "3B82F6").status != 0, "A catalog with no accent must fail so the flat icon is used")
let realCatalog = [UInt8](try! Data(contentsOf: claudeCatalog))
let realBlue = recolor(claudeCatalog, "claude-blue", "3B82F6")
precondition(realBlue.status == 0, "The real Claude catalog must recolour")
let realBlueBytes = [UInt8](try! Data(contentsOf: realBlue.output))
precondition(realBlueBytes.count == realCatalog.count, "The real Claude catalog changed size")
let changed = zip(realBlueBytes, realCatalog).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
precondition(!changed.isEmpty && changed.last! - changed.first! < 4096, "Only the Claude accent colours may change")

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
print("Icon QA passed: Claude glyph/alpha/contrast, Claude catalog accent recolouring, real icon variants, and exact ChatGPT compatibility for four tints")
print(root.appendingPathComponent("preview.png").path)
