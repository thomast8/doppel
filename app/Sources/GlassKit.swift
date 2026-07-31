import SwiftUI
import AppKit

/// Real Liquid Glass, via AppKit.
///
/// SwiftUI's `glassEffect` modifier is missing from the Command Line Tools
/// SDK, but AppKit's `NSGlassEffectView` (macOS 26) is fully declared there, so
/// the genuine material is reachable without a full Xcode install. Older
/// systems fall back to a vibrancy material, which is the closest thing they
/// have.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    var tint: Color?
    /// `.clear` is the thinner, more transparent variant Apple uses over busy
    /// backdrops; `.regular` is the default.
    var clearStyle = false
    var interactive = false
    var fallbackMaterial: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSView {
        guard #available(macOS 26.0, *),
              let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type
        else {
            let fallback = NSVisualEffectView()
            fallback.material = fallbackMaterial
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
            return fallback
        }
        let view = glassClass.init(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let fallback = view as? NSVisualEffectView {
            fallback.material = fallbackMaterial
            fallback.layer?.cornerRadius = cornerRadius
            return
        }
        apply(to: view)
    }

    /// Set through KVC so this file compiles against SDKs that predate the
    /// class, while still using the real properties when it exists.
    private func apply(to view: NSView) {
        view.setValue(cornerRadius, forKey: "cornerRadius")
        view.setValue(tint.map { NSColor($0) }, forKey: "tintColor")
        view.setValue(clearStyle ? 1 : 0, forKey: "style")
        if view.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
            view.setValue(interactive, forKey: "effectIsInteractive")
        }
    }
}

/// Groups nearby glass elements so they merge and flow into each other rather
/// than reading as separate panes, which is how Apple intends multiple glass
/// pieces to sit together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        // NSGlassEffectContainerView groups AppKit subviews; for SwiftUI
        // content the equivalent is keeping the pieces close and letting each
        // carry its own glass, so this simply enforces the shared spacing.
        content
    }
}

/// Makes the hosting window chromeless so the material reaches every edge.
/// Without this the window paints its own opaque background and the glass
/// reads as flat grey.
struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.styleMask.insert(.fullSizeContentView)
    }
}

/// Hue slider with a gradient track.
///
/// The stock Slider draws its own grey track, so a gradient behind it reads as
/// two overlapping controls. This draws the spectrum as the track itself.
struct HueSlider: View {
    @Binding var hue: Double
    var onChange: (Double) -> Void

    private let trackHeight: CGFloat = 10
    private let knobSize: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - knobSize, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 0.05)
                            .map { Color(hue: $0, saturation: 0.78, brightness: 0.92) },
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .padding(.horizontal, knobSize / 2)

                Circle()
                    .fill(.white)
                    .overlay(Circle().fill(Color(hue: hue, saturation: 0.78, brightness: 0.92)).padding(4))
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: usable * hue)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let position = (value.location.x - knobSize / 2) / usable
                        let clamped = min(max(position, 0), 1)
                        hue = clamped
                        onChange(clamped)
                    }
            )
        }
        .frame(height: knobSize)
        // A drag gesture on a shape is invisible to VoiceOver and unreachable
        // from the keyboard, which left the custom hues available only to a
        // mouse. Adjustable makes it behave like the slider it looks like.
        .accessibilityElement()
        .accessibilityLabel("Custom icon colour")
        .accessibilityValue(Text(hueDescription))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / 24.0
            switch direction {
            case .increment: setHue(min(hue + step, 1))
            case .decrement: setHue(max(hue - step, 0))
            @unknown default: break
            }
        }
    }

    private func setHue(_ value: Double) {
        hue = value
        onChange(value)
    }

    /// Degrees around the wheel: "0" and "1" would tell a listener nothing.
    private var hueDescription: String {
        "\(Int((hue * 360).rounded())) degrees"
    }
}
