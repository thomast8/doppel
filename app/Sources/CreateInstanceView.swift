import SwiftUI
import AppKit

/// Form state lives in an ObservableObject because the SwiftUI @State macro
/// is unavailable under a Command Line Tools-only toolchain.
final class CreateForm: ObservableObject {
    @Published var name = ""
    @Published var color = Color(hex: "F28C28")
    @Published var customHue: Double = 0.08
    @Published var creating = false
    @Published var loaded = false
    @Published var errorMessage: String?
}

/// Layout follows Apple's Liquid Glass guidance: the window is the content
/// layer, and glass is reserved for the pieces that float above it — the icon
/// tile and the action bar. Radii are concentric: an inner shape's radius is
/// its container's radius minus the padding between them.
struct CreateInstanceView: View {
    @ObservedObject var store: InstanceStore
    /// When set, the window edits that instance instead of creating one.
    var editing: Instance?
    @StateObject private var form = CreateForm()
    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { editing != nil }

    private enum Radius {
        static let panel: CGFloat = 20
        static let field: CGFloat = 12
        static let tile: CGFloat = 16
    }

    private var trimmedName: String {
        form.name.trimmingCharacters(in: .whitespaces)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && !form.creating && (store.primaryInstalled || isEditing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if !store.primaryInstalled && !isEditing { missingPrimaryNotice }
            nameField
            colourSection
            if let errorMessage = form.errorMessage { errorRow(errorMessage) }
            Spacer(minLength: 4)
            actionBar
        }
        .padding(28)
        .frame(width: 440)
        .onAppear {
            // Load what the instance actually is, so the form never misreports
            // its colour or name back to the user.
            guard let editing, !form.loaded else { return }
            form.loaded = true
            form.name = editing.name
            if !editing.tint.isEmpty {
                form.color = Color(hex: editing.tint)
                form.customHue = Color(hex: editing.tint).hueComponent
            }
        }
        .background(WindowStyler())
        .background(
            GlassBackground(cornerRadius: 0, clearStyle: false, fallbackMaterial: .underWindowBackground)
                .ignoresSafeArea()
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(color: form.color, name: trimmedName, radius: Radius.tile)
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing ? "Edit instance" : "New instance")
                    .font(.system(size: 21, weight: .semibold))
                Text(isEditing
                     ? "Renaming keeps this instance's account and chats."
                     : "Its own app, account and history.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("Name")
            TextField("", text: $form.name, prompt: Text("ChatGPT Personal").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .fill(.black.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .onSubmit { if canCreate { submit() } }
        }
    }

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel("Icon colour")
            TintPicker(color: $form.color, customHue: $form.customHue)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(isEditing
                 ? "The app is rebuilt with the new name and colour."
                 : (store.primaryInstalled
                    ? "Everything else is derived from the name."
                    : "Install ChatGPT first."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            glassButton("Cancel", prominent: false) { dismiss() }
                .keyboardShortcut(.cancelAction)
            glassButton(form.creating ? (isEditing ? "Saving…" : "Creating…")
                                      : (isEditing ? "Save" : "Create"),
                        prominent: true) { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var missingPrimaryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ChatGPT isn't installed", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
            Text("Instances are built from your own copy. Install it, then come back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                glassButton("Get ChatGPT", prominent: false) {
                    NSWorkspace.shared.open(InstanceStore.primaryDownloadURL)
                }
                glassButton("Check again", prominent: false) { store.reload() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(.orange.opacity(0.14)))
    }

    // MARK: - Pieces

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(.none)
    }

    /// Large macOS controls are capsules under Liquid Glass, so both buttons
    /// take the same shape; only the tint separates primary from secondary.
    ///
    /// buttonBorderShape alone is not enough: a disabled prominent button drops
    /// its glass for a plain rounded rectangle, which then sits next to the
    /// enabled capsule. Clipping pins the shape in every state, and is a no-op
    /// when the style already draws a capsule.
    @ViewBuilder
    private func glassButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(title, action: action)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        Group {
            if #available(macOS 26.0, *) {
                if prominent {
                    button.buttonStyle(.glassProminent)
                } else {
                    button.buttonStyle(.glass)
                }
            } else {
                if prominent {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            }
        }
        .clipShape(Capsule(style: .continuous))
    }

    private func submit() {
        form.creating = true
        form.errorMessage = nil
        let finish: (String?) -> Void = { [form] failure in
            form.creating = false
            if let failure {
                form.errorMessage = failure
            } else {
                dismiss()
            }
        }
        if let editing {
            store.edit(editing, newName: trimmedName, tintHex: form.color.rgbHex, completion: finish)
        } else {
            store.create(name: trimmedName, tintHex: form.color.rgbHex, completion: finish)
        }
    }
}

/// The icon preview is the one place the chosen colour becomes a real object:
/// tinted glass, showing what the instance's icon will pick up.
struct IconTile: View {
    let color: Color
    let name: String
    let radius: CGFloat

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "C" : letters.uppercased()
    }

    var body: some View {
        ZStack {
            GlassBackground(cornerRadius: radius, tint: color, interactive: true)
            Text(initials)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: 58, height: 58)
    }
}

extension Color {
    /// RRGGBB for the CLI's --tint flag.
    var rgbHex: String {
        let srgb = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.95, green: 0.55, blue: 0.16, alpha: 1)
        let r = Int(round(srgb.redComponent * 255))
        let g = Int(round(srgb.greenComponent * 255))
        let b = Int(round(srgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
