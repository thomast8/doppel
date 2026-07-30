import SwiftUI
import AppKit

/// Form state lives in an ObservableObject because the SwiftUI @State macro
/// is unavailable under a Command Line Tools-only toolchain.
final class CreateForm: ObservableObject {
    @Published var name = ""
    @Published var color = Color(hex: "F28C28")
    @Published var customHue: Double = 0.08
    @Published var creating = false
    @Published var errorMessage: String?
}

struct CreateInstanceView: View {
    @ObservedObject var store: InstanceStore
    @StateObject private var form = CreateForm()
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        form.name.trimmingCharacters(in: .whitespaces)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && !form.creating && store.primaryInstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !store.primaryInstalled {
                missingPrimaryNotice
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $form.name, prompt: Text("ChatGPT Personal"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.quaternary.opacity(0.5)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5))
                    .onSubmit { if canCreate { create() } }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Icon colour")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                TintPicker(color: $form.color, customHue: $form.customHue)
            }

            Text("The instance gets its own icon, Dock identity and data. Everything else is derived from the name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage = form.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Spacer()
                cancelButton
                createButton
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(WindowMaterial())
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconPreview(color: form.color, name: trimmedName.isEmpty ? "ChatGPT Personal" : trimmedName)
            VStack(alignment: .leading, spacing: 3) {
                Text("New instance")
                    .font(.title2.weight(.semibold))
                Text("A separate app, with its own account and history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var missingPrimaryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The ChatGPT app isn't installed yet", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
            Text("Instances are built from your own local copy, so install it first, then come back here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Get ChatGPT…") { NSWorkspace.shared.open(InstanceStore.primaryDownloadURL) }
                Button("Check again") { store.reload() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.yellow.opacity(0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.yellow.opacity(0.35), lineWidth: 0.5))
    }

    @ViewBuilder
    private var cancelButton: some View {
        let button = Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .controlSize(.large)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var createButton: some View {
        let button = Button(form.creating ? "Creating…" : "Create") { create() }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!canCreate)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func create() {
        form.creating = true
        form.errorMessage = nil
        store.create(name: trimmedName, tintHex: form.color.rgbHex) { [form] failure in
            form.creating = false
            if let failure {
                form.errorMessage = failure
            } else {
                dismiss()
            }
        }
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
