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
        // MenuBarExtra reliably promotes a direct Image into the status item.
        // Wrapping a custom Shape in a Group produced an empty slot on macOS.
        Image(nsImage: store.permissionIssues.isEmpty
              ? DoppelMenuBarMark.image
              : DoppelMenuBarMark.warningImage)
            .renderingMode(.template)
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

/// Doppel's original mark at menu-bar scale: two asymmetric conversation
/// bubbles, offset on the same diagonal as the app artwork. Keeping the geometry
/// local means this identity has no dependency on another app's trademark.
private enum DoppelMenuBarMark {
    /// NSImage's drawing handler is resolution-independent, so this stays sharp
    /// on Retina displays while presenting MenuBarExtra with the direct image it
    /// expects. `isTemplate` lets macOS supply the correct light/dark tint.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(1.45)
            context.setStrokeColor(NSColor.black.cgColor)

            context.saveGState()
            context.setAlpha(0.46)
            context.addPath(bubblePath(in: CGRect(x: 0.5, y: 6.8,
                                                  width: 12.2, height: 9.4)))
            context.strokePath()
            context.restoreGState()

            context.addPath(bubblePath(in: CGRect(x: 5.3, y: 1.4,
                                                  width: 12.2, height: 9.4)))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let warningImage: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.bubble.fill",
                            accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                       accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    private static func bubblePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tailHeight = rect.height * 0.20
        let bodyBottom = rect.minY + tailHeight
        let radius = min(rect.width * 0.16, (rect.height - tailHeight) * 0.30)
        let tailStart = rect.minX + rect.width * 0.22
        let tailTip = CGPoint(x: rect.minX + rect.width * 0.09, y: rect.minY)
        let tailEnd = rect.minX + rect.width * 0.41

        path.move(to: CGPoint(x: rect.minX + radius, y: bodyBottom))
        path.addLine(to: CGPoint(x: tailStart, y: bodyBottom))
        path.addQuadCurve(to: tailTip,
                          control: CGPoint(x: tailStart - rect.width * 0.035,
                                           y: bodyBottom - tailHeight * 0.48))
        path.addQuadCurve(to: CGPoint(x: tailEnd, y: bodyBottom),
                          control: CGPoint(x: tailTip.x + rect.width * 0.16,
                                           y: tailTip.y + tailHeight * 0.36))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: bodyBottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bodyBottom + radius),
                          control: CGPoint(x: rect.maxX, y: bodyBottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: bodyBottom),
                          control: CGPoint(x: rect.minX, y: bodyBottom))
        path.closeSubpath()
        return path
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
            let permissions = store.permissionStatuses.filter { $0.instanceID == instance.id }
            Menu {
                Menu("Privacy Permissions") {
                    if permissions.isEmpty {
                        Text(store.checkingPermissions ? "Checking…" : "No status available")
                    } else {
                        ForEach(permissions) { permission in
                            if permission.action != .unavailable {
                                Button {
                                    store.handlePermission(permission)
                                } label: {
                                    Label("\(permission.label) — \(permission.statusLabel)",
                                          systemImage: permission.systemImage)
                                }
                                .disabled(store.busy.contains("permissions"))
                            } else {
                                Label("\(permission.label) — \(permission.statusLabel)",
                                      systemImage: permission.systemImage)
                                    .disabled(true)
                            }
                        }
                    }
                    Divider()
                    if store.busy.contains("permissions") {
                        Text("Waiting for macOS…")
                    } else {
                        Text("Select Not requested to ask macOS for this instance.")
                    }
                }
                Divider()
                Button("Launch") { store.launch(instance) }
                    .disabled(store.busy.contains(instance.id))
                Button("Rebuild & Reopen") { store.rebuild(instance) }
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
                if issues.isEmpty {
                    Text(instance.name)
                } else {
                    Label(instance.name, systemImage: "exclamationmark.triangle.fill")
                }
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
        Menu("Native Tools") {
            if let status = store.nativeToolsStatus {
                Label(status.computerUse == .ready
                      ? "Computer Use — Ready"
                      : "Computer Use — Available on demand",
                      systemImage: status.computerUse == .ready
                          ? "checkmark.circle.fill" : "circle.dotted")
                if status.chronicle == .running {
                    Label(status.chronicleIsFresh
                          ? "Chronicle — Recording"
                          : "Chronicle — Recording is stale",
                          systemImage: status.chronicleIsFresh
                              ? "record.circle.fill" : "exclamationmark.circle")
                    if !status.chronicleHost.isEmpty {
                        Text("Shared recorder: \(status.chronicleHost)")
                    }
                } else {
                    Label("Chronicle — Not running", systemImage: "pause.circle")
                }
                Divider()
                // Owning a registration is not what lets an instance browse:
                // any instance can use a running extension host. It decides
                // whose host Chrome launches, which matters when that one is
                // missing or older than the rest.
                if status.inAppBrowserUnavailable {
                    Label("In-app browser — Not available in instances",
                          systemImage: "xmark.circle")
                    Text("ChatGPT only opens it for an app signed by OpenAI.")
                }
                if status.browserHosts.isEmpty {
                    Label("Browser extension — Not installed", systemImage: "circle.dotted")
                } else {
                    // Only instances that already have an extension host of
                    // their own are offered: the CLI refuses the rest rather
                    // than pointing the registration at a path that is not
                    // there, so offering them would be a dead end.
                    let eligible = store.instances.filter {
                        $0.installed && status.instancesWithBrowserHost.contains($0.name)
                    }
                    let hidden = store.instances.filter {
                        $0.installed && !status.instancesWithBrowserHost.contains($0.name)
                    }
                    // Each browser is assigned on its own, because each has its
                    // own registration and so two instances can browse at the
                    // same time in two different browsers.
                    ForEach(status.browserHosts, id: \.browser) { host in
                        if eligible.isEmpty {
                            Label("\(host.browser) — \(host.owner)",
                                  systemImage: "checkmark.circle.fill")
                        } else {
                            Menu("\(host.browser) — \(host.owner)") {
                                ForEach(eligible) { instance in
                                    Button(instance.name) {
                                        store.claimBrowserHost(for: instance, browser: host.browser)
                                    }
                                    .disabled(host.ownerNames.contains(instance.name)
                                              || store.busy.contains("native-tools"))
                                }
                            }
                        }
                    }
                    if status.browserHosts.count > 1, !eligible.isEmpty {
                        Menu("Give Every Browser To") {
                            ForEach(eligible) { instance in
                                Button(instance.name) {
                                    store.claimBrowserHost(for: instance)
                                }
                                .disabled(status.browserOwnerNames.contains(instance.name)
                                          || store.busy.contains("native-tools"))
                            }
                        }
                    }
                    if !hidden.isEmpty {
                        Text(hidden.count == 1
                             ? "\(hidden[0].name) must run once before it can hold one."
                             : "\(hidden.count) instances must run once before they can hold one.")
                    }
                    Text("Any instance can use a running one; this picks whose host starts it.")
                }
                Divider()
                if status.discoverableRollbacks > 0 {
                    let noun = status.discoverableRollbacks == 1 ? "Entry" : "Entries"
                    Button("Repair \(status.discoverableRollbacks) Duplicate App \(noun)") {
                        store.repairNativeTools()
                    }
                    .disabled(store.busy.contains("native-tools"))
                } else {
                    Label("App discovery — Clean", systemImage: "checkmark.circle.fill")
                }
                Text("Managed instances are resolved by exact installed path.")
            } else {
                Text(store.checkingNativeTools ? "Checking…" : "Status unavailable")
            }
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
