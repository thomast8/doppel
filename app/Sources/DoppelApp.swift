import SwiftUI

@main
struct DoppelApp: App {
    @StateObject private var store = InstanceStore()

    init() {
        if !SingleInstance.acquire() {
            // Another menu-bar instance is already running; a second icon would
            // just confuse. Leave quietly.
            exit(0)
        }
    }

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
                Divider()
                Button("Remove…") { confirmRemove(instance) }
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
        Toggle("Start at Login", isOn: Binding(
            get: { store.loginItemEnabled },
            set: { store.setLoginItem($0) }
        ))
        ForEach(store.errors.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
            Text("\(key): \(message)").foregroundStyle(.red)
        }
        Divider()
        Button("Quit Doppel") { NSApplication.shared.terminate(nil) }
    }

    /// Removal moves the app to the Trash and keeps account data unless the
    /// user explicitly opts into deleting it, so the dialog states both.
    private func confirmRemove(_ instance: Instance) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove “\(instance.name)”?"
        alert.informativeText = """
            The app moves to the Trash and can be rebuilt at any time.
            Its account data (chats and login) is kept unless you tick below.
            """
        alert.alertStyle = .warning
        let purge = NSButton(checkboxWithTitle: "Also move this account's data to the Trash", target: nil, action: nil)
        purge.state = .off
        alert.accessoryView = purge
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(instance, purgeData: purge.state == .on)
    }
}
