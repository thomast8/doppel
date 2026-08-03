import SwiftUI

@main
struct DoppelApp: App {
    @StateObject private var store = InstanceStore()

    init() {
        // Scriptable hook, also how the login-item path is tested without
        // driving the menu: Doppel --login-item {on|off|status}
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--login-item") {
            let action = index + 1 < arguments.count ? arguments[index + 1] : "status"
            switch action {
            case "on", "off":
                if let failure = LoginItem.setEnabled(action == "on") {
                    FileHandle.standardError.write(Data("\(failure)\n".utf8))
                    exit(1)
                }
                print(LoginItem.isEnabled ? "on" : "off")
            default:
                print(LoginItem.isEnabled ? "on" : "off")
            }
            exit(0)
        }

        // Renders the window to a PNG without a screen or any capture
        // permission, so the UI can be reviewed as part of QA:
        //   Doppel --render-ui <path.png> [edit]
        if let index = arguments.firstIndex(of: "--render-ui") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : "/tmp/doppel-ui.png"
            let editing = arguments.contains("edit")
            UIRenderer.render(to: URL(fileURLWithPath: path), editing: editing)
            exit(0)
        }

        if !SingleInstance.acquire() {
            // Another menu-bar instance is already running; a second icon would
            // just confuse. Leave quietly.
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        Window("New Doppel Instance", id: "create-instance") {
            CreateInstanceView(store: store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Edit Doppel Instance", id: "edit-instance", for: String.self) { $slug in
            if let slug, let instance = store.instances.first(where: { $0.id == slug }) {
                CreateInstanceView(store: store, editing: instance)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The menu bar icon. It is also the earliest reliably-rendered view, which is
/// what --show-create hangs off: the window can be opened at launch without
/// driving the menu by hand.
struct MenuBarLabel: View {
    @ObservedObject var store: InstanceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.permissionIssues.isEmpty
              ? "square.on.square"
              : "exclamationmark.square.fill")
            .accessibilityLabel(store.permissionIssues.isEmpty
                                ? "Doppel"
                                : "Doppel: managed app permissions need attention")
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("--show-create") else { return }
                openWindow(id: "create-instance")
                NSApp.activate(ignoringOtherApps: true)
            }
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
            let issues = store.permissionIssues.filter { $0.instanceID == instance.id }
            Menu {
                if !issues.isEmpty {
                    Section("Needs Attention") {
                        ForEach(issues) { issue in
                            Button {
                                store.showPermissionIssues(for: instance)
                            } label: {
                                Label("\(issue.label) — \(issue.statusLabel)",
                                      systemImage: issue.systemImage)
                            }
                        }
                    }
                    Divider()
                }
                Button("Launch") { store.launch(instance) }
                    .disabled(store.busy.contains(instance.id))
                Button("Rebuild") { store.rebuild(instance) }
                    .disabled(store.busy.contains(instance.id))
                Button("Rename or Recolour…") {
                    openWindow(id: "edit-instance", value: instance.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .disabled(store.busy.contains(instance.id))
                Divider()
                Button("Remove…") { confirmRemove(instance) }
                    .disabled(store.busy.contains(instance.id))
                if store.busy.contains(instance.id) {
                    Text("Working…")
                }
            } label: {
                Label(instance.name,
                      systemImage: issues.isEmpty ? "app" : "exclamationmark.triangle.fill")
            }
        }
        Divider()
        if !store.permissionIssues.isEmpty {
            Button("Permissions Need Attention (\(store.permissionIssues.count))…") {
                store.showPermissionIssues()
            }
        } else if store.checkingPermissions {
            Text("Checking Managed App Permissions…")
        }
        Button("New Instance…") {
            openWindow(id: "create-instance")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Refresh") { store.reload() }
        if store.busy.contains("update") {
            Text("Updating ChatGPT and managed instances…")
        } else if let update = store.chatGPTUpdate {
            Button(update.state == .ready
                   ? "Restart to Install ChatGPT \(update.targetVersion)…"
                   : "Install ChatGPT \(update.targetVersion)…") {
                store.beginKnownUpdate()
            }
        } else {
            Button(store.checkingForUpdates
                   ? "Checking for ChatGPT Updates…"
                   : "Check for ChatGPT Updates…") {
                store.checkForUpdates(userInitiated: true)
            }
            .disabled(store.checkingForUpdates)
        }
        if !store.signingReady {
            Button(store.busy.contains("signing")
                   ? "Setting up secure signing…"
                   : "Set Up Secure Signing…") { store.setUpSigning() }
                .disabled(store.busy.contains("signing"))
        }
        Toggle("Start at Login", isOn: Binding(
            get: { store.loginItemEnabled },
            set: { store.setLoginItem($0) }
        ))
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
        // Keep Remove where a destructive action belongs, on the right, but
        // move the Return key to Cancel: a dialog that appears over whatever
        // else you were doing should not delete an account because you were
        // mid-keystroke.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(instance, purgeData: purge.state == .on)
    }
}
