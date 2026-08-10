import SwiftUI
import AppKit

/// Renders the create/edit window to an image.
///
/// Reviewing the interface otherwise needs a screen capture, which macOS gates
/// behind a permission that a headless or scripted run will not have. Drawing
/// the real view hierarchy offscreen sidesteps that entirely. AppKit-backed
/// glass and controls use matching SwiftUI stand-ins because they cannot
/// render into ImageRenderer without a window.
@MainActor
enum UIRenderer {
    static func render(to url: URL, editing: Bool) {
        let store = InstanceStore()
        // Give the store a moment to populate from the CLI so the rendered
        // window shows real instances rather than an empty state.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let sample = store.instances.first
            ?? Instance(id: "sample", name: "ChatGPT Personal",
                        appPath: "", installed: true, tint: "A855F7", engine: .clone)

        let view = CreateInstanceView(store: store, editing: editing ? sample : nil,
                                      renderingDocumentation: true)
            .frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("render produced no image\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode the image\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
