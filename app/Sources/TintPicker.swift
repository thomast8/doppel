import SwiftUI
import AppKit

/// Inline tint picker.
///
/// SwiftUI's ColorPicker opens NSColorPanel — a separate floating window with
/// colour wheels, palettes and an eyedropper, none of which suit picking one
/// icon tint. This keeps the choice in the sheet: curated tints that read well
/// at icon size, plus a hue slider for anything else.
struct TintPicker: View {
    @Binding var color: Color
    @Binding var customHue: Double

    private static let swatches: [(name: String, hex: String)] = [
        ("Orange", "F28C28"), ("Amber", "F59E0B"), ("Red", "EF4444"), ("Pink", "EC4899"),
        ("Purple", "A855F7"), ("Indigo", "6366F1"), ("Blue", "3B82F6"), ("Cyan", "06B6D4"),
        ("Teal", "14B8A6"), ("Green", "1FA97E"), ("Lime", "84CC16"), ("Graphite", "64748B"),
    ]

    private var selectedHex: String { color.rgbHex }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(Self.swatches, id: \.hex) { swatch in
                    Swatch(
                        color: Color(hex: swatch.hex),
                        isSelected: selectedHex.caseInsensitiveCompare(swatch.hex) == .orderedSame,
                        label: swatch.name
                    ) {
                        color = Color(hex: swatch.hex)
                    }
                }
            }

            HStack(spacing: 10) {
                Text("Custom")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Slider(value: $customHue, in: 0...1) { editing in
                    if editing { color = Color(hue: customHue, saturation: 0.78, brightness: 0.92) }
                }
                .onChange(of: customHue) { _ in
                    color = Color(hue: customHue, saturation: 0.78, brightness: 0.92)
                }
                .background(
                    Capsule()
                        .fill(LinearGradient(
                            colors: stride(from: 0.0, through: 1.0, by: 0.1)
                                .map { Color(hue: $0, saturation: 0.78, brightness: 0.92) },
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 4)
                )
            }
        }
    }
}

private struct Swatch: View {
    let color: Color
    let isSelected: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.gradient)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                .frame(height: 26)
                .padding(2)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A rounded-square preview of what the instance's icon tint will look like.
struct IconPreview: View {
    let color: Color
    let name: String

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(color.gradient)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            .overlay(
                Text(initials)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95)))
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Window background material. The `glassEffect` modifier is not present in the
/// Command Line Tools SDK, so the system material — which is the Liquid Glass
/// material on macOS 26 and later — is applied through AppKit instead.
struct WindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
