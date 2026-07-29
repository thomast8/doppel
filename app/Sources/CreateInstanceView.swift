import SwiftUI
import AppKit

/// Form state lives in an ObservableObject because the SwiftUI @State macro
/// is unavailable under a Command Line Tools-only toolchain.
final class CreateForm: ObservableObject {
    @Published var name = ""
    @Published var color = Color(red: 0.95, green: 0.55, blue: 0.16)
    @Published var creating = false
    @Published var errorMessage: String?
}

struct CreateInstanceView: View {
    @ObservedObject var store: InstanceStore
    @StateObject private var form = CreateForm()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New instance")
                .font(.headline)
            if !store.primaryInstalled {
                Text("The ChatGPT app isn't installed yet. Doppel builds instances from your own local copy, so install it first, then come back here.")
                    .font(.callout)
                HStack {
                    Button("Get ChatGPT…") {
                        NSWorkspace.shared.open(InstanceStore.primaryDownloadURL)
                    }
                    Button("Check again") { store.reload() }
                }
                Divider()
            }
            TextField("App name", text: $form.name, prompt: Text("ChatGPT Personal"))
                .textFieldStyle(.roundedBorder)
            ColorPicker("Icon color", selection: $form.color, supportsOpacity: false)
            Text("The instance gets its own icon, Dock identity, and data. Everything else is derived from the name.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let errorMessage = form.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(form.creating ? "Creating…" : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || form.creating || !store.primaryInstalled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        form.creating = true
        form.errorMessage = nil
        let trimmed = form.name.trimmingCharacters(in: .whitespaces)
        store.create(name: trimmed, tintHex: form.color.rgbHex) { [form] failure in
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
