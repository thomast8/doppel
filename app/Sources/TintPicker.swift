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
    /// True when the instance should keep the app's own artwork untinted.
    @Binding var useOriginal: Bool

    private static let swatches: [(name: String, hex: String)] = [
        ("Orange", "F28C28"), ("Red", "EF4444"), ("Pink", "EC4899"), ("Purple", "A855F7"),
        ("Indigo", "6366F1"), ("Blue", "3B82F6"), ("Teal", "14B8A6"), ("Green", "1FA97E"),
        ("Lime", "84CC16"), ("Graphite", "64748B"),
    ]

    private var selectedHex: String { color.rgbHex }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                OriginalSwatch(isSelected: useOriginal) { useOriginal = true }
                    .frame(maxWidth: .infinity)
                ForEach(Self.swatches, id: \.hex) { swatch in
                    Swatch(
                        color: Color(hex: swatch.hex),
                        isSelected: !useOriginal
                            && selectedHex.caseInsensitiveCompare(swatch.hex) == .orderedSame,
                        label: swatch.name
                    ) {
                        useOriginal = false
                        color = Color(hex: swatch.hex)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HueSlider(hue: $customHue) { hue in
                useOriginal = false
                color = Color(hue: hue, saturation: 0.78, brightness: 0.92)
            }
        }
    }
}

/// Keeps the app's own icon. Drawn as the untinted artwork would read: a light
/// disc, distinct from every colour beside it.
private struct OriginalSwatch: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(white: 0.97))
                .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    Image(systemName: isSelected ? "checkmark" : "circle.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(height: 26)
                .padding(2)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .help("Original — the app's own icon, untinted")
        .accessibilityLabel("Original icon")
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

extension Color {
    /// Hue in 0...1, used to place the custom slider on an existing colour.
    var hueComponent: Double {
        let srgb = NSColor(self).usingColorSpace(.sRGB) ?? .orange
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Double(hue)
    }

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
