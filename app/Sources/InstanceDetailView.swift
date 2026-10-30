import SwiftUI
import AppKit

/// Everything about one instance in one window, replacing the submenus the
/// menu used to nest three deep: permissions, engine, Remote Access and the
/// two maintenance actions.
struct InstanceDetailView: View {
    @ObservedObject var store: InstanceStore
    let slug: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let instance = store.instances.first(where: { $0.id == slug }) {
                content(instance)
            } else {
                Text(store.listLoaded ? "This instance no longer exists." : "Loading…")
                    .foregroundStyle(.secondary)
                    .frame(width: 520, height: 200)
            }
        }
    }

    private func content(_ instance: Instance) -> some View {
        let activity = store.activity(for: instance)
        let busy = store.engineOperationBusy
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(color: instance.tileColor, name: instance.name, radius: 14,
                         renderingDocumentation: true, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(instance.name).font(.system(size: 19, weight: .semibold))
                    Text(Self.statusText(activity))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename or Recolour…") {
                    openWindow(id: "edit-instance", value: instance.id)
                }
                .disabled(busy)
                if activity == .running {
                    Button("Show") { store.show(instance) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open") { store.launch(instance) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !instance.installed)
                }
            }
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)

            Form {
                Section {
                    PermissionRows(store: store, instanceID: instance.id)
                } header: {
                    Text(instance.usesBuiltInBrowser ? "Privacy permissions for the Doppel engine"
                                                     : "Privacy permissions")
                } footer: {
                    Text(instance.usesBuiltInBrowser
                         ? "Official ChatGPT uses its own macOS permissions. These apply after switching back to the Doppel engine."
                         : "Each instance asks macOS on its own. Optional ones can wait until a feature needs them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The fallback engine and Remote Access are built on
                // ChatGPT's own runtime; a Claude instance has neither.
                if instance.appKind == .chatgpt {
                    Section("Engine") {
                        Picker("Engine", selection: Binding(
                            get: { instance.engine },
                            set: { engine in
                                guard engine != instance.engine else { return }
                                if engine == .vendor {
                                    store.assignBuiltInBrowser(to: instance)
                                } else {
                                    store.releaseBuiltInBrowser()
                                }
                            })) {
                            engineOption("Doppel engine",
                                         detail: "Recommended. Its own app, icon and data.")
                                .tag(InstanceEngine.clone)
                            engineOption("Official ChatGPT (fallback)",
                                         detail: "Only if a ChatGPT update breaks this clone. Same account and chats.")
                                .tag(InstanceEngine.vendor)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .disabled(busy || (!instance.usesBuiltInBrowser && !store.primaryInstalled))
                    }

                    Section("Remote Access") {
                        row("Let another device run tasks in this account.", detail: nil) {
                            Button("Open…") { openWindow(id: "remote-access", value: instance.id) }
                                .disabled(busy)
                        }
                    }
                }

                Section("Maintenance") {
                    row("Rebuild and reopen",
                        detail: "Fixes a broken clone. Keeps the account and chats.") {
                        Button("Rebuild") { store.rebuild(instance) }.disabled(busy)
                    }
                    if instance.appKind == .claude {
                        row("Import Code history",
                            detail: "Copies matching local Code sessions from the original Claude app.") {
                            Button("Import…") { store.importClaudeSessions(instance) }.disabled(busy)
                        }
                    }
                    row("Remove instance",
                        detail: "The app goes to the Trash. Account data is kept unless you choose otherwise.") {
                        Button("Remove…", role: .destructive) { store.confirmRemove(instance) }
                            .disabled(busy)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 640)
        .navigationTitle(instance.name)
    }

    private func engineOption(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func row<Trailing: View>(_ title: String, detail: String?,
                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }

    static func statusText(_ activity: InstanceActivity) -> String {
        switch activity {
        case .working: return "Working…"
        case .attention(let message): return message
        case .checkerOutdated: return "Permission checker needs a rebuild"
        case .running: return "Running"
        case .stopped: return "Not running"
        case .notInstalled: return "App missing. Rebuild to restore it."
        }
    }
}

/// One instance's privacy permissions, each with the one action that can
/// change it. Shared by the instance window and the setup guide.
struct PermissionRows: View {
    @ObservedObject var store: InstanceStore
    let instanceID: String

    var body: some View {
        let permissions = store.permissionStatuses.filter { $0.instanceID == instanceID }
        if permissions.isEmpty {
            Text(store.checkingPermissions ? "Checking…" : "No status available yet.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(permissions) { permission in
                HStack(spacing: 10) {
                    Image(systemName: permission.systemImage)
                        .foregroundStyle(Self.color(permission))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.label)
                        Text(Self.explanation(permission))
                            .font(.caption)
                            .foregroundStyle(permission.needsAttention ? Color.red : Color.secondary)
                    }
                    Spacer()
                    if let title = Self.actionTitle(permission) {
                        Button(title) { store.handlePermission(permission) }
                            .disabled(store.busy.contains("permissions"))
                    }
                }
            }
            if store.busy.contains("permissions") {
                Text("Waiting for macOS…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func color(_ permission: PermissionIssue) -> Color {
        if permission.status == "granted" { return .green }
        if permission.needsAttention { return .red }
        if permission.status == "missing" || permission.status == "unconfirmed" { return .orange }
        return .secondary
    }

    static func explanation(_ permission: PermissionIssue) -> String {
        switch permission.status {
        case "granted": return "Allowed"
        case "not-requested": return "Not asked yet. Optional until a feature needs it."
        case "missing", "unconfirmed": return "macOS cannot confirm this. Check in System Settings."
        case "denied": return "Denied. Turn it on in System Settings."
        case "restricted": return "Restricted by a profile or parental controls."
        case "outdated": return "The permission checker needs a rebuild."
        case "error": return "The check failed."
        default: return permission.statusLabel
        }
    }

    /// Granted rows keep a shortcut to their Settings pane, as the menu did,
    /// so a grant can also be withdrawn from here.
    static func actionTitle(_ permission: PermissionIssue) -> String? {
        switch permission.action {
        case .unavailable: return nil
        case .requestNative: return "Allow"
        case .openSettings: return permission.status == "granted" ? "Settings…" : "Open Settings"
        }
    }
}
