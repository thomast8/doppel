import SwiftUI

@main
struct DoppelApp: App {
    @StateObject private var store = InstanceStore()

    var body: some Scene {
        MenuBarExtra("Doppel", systemImage: "square.on.square") {
            MenuContent(store: store)
        }
        Window("New Doppel Instance", id: "create-instance") {
            CreateInstanceView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuContent: View {
    @ObservedObject var store: InstanceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.instances.isEmpty {
            Text("No instances yet")
            Text("Create one with `doppel create`")
        }
        ForEach(store.instances) { instance in
            Menu(instance.name) {
                Button("Launch") { store.launch(instance) }
                    .disabled(store.busy.contains(instance.id))
                Button("Rebuild") { store.rebuild(instance) }
                    .disabled(store.busy.contains(instance.id))
                if store.busy.contains(instance.id) {
                    Text("Working…")
                }
            }
        }
        Divider()
        Button("New Instance…") {
            openWindow(id: "create-instance")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { store.reload() }
        ForEach(store.errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
            Text("\(key): \(message)").foregroundStyle(.red)
        }
        Divider()
        Button("Quit Doppel") { NSApplication.shared.terminate(nil) }
    }
}
