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
        let busy = store.engineOperationBusy
        return Form {
            Section {
                PermissionRows(store: store, instanceID: instance.id)
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    hero(instance).heroHeader()
                    Text(instance.usesBuiltInBrowser ? "Privacy permissions for the Doppel engine"
                                                     : "Privacy permissions")
                }
            } footer: {
                footnote(instance.usesBuiltInBrowser
                         ? "Official ChatGPT uses its own macOS permissions. These apply after switching back to the Doppel engine."
                         : "Each instance asks macOS on its own. Optional ones can wait until a feature needs them.")
            }

            // The fallback engine and Remote Access are built on
            // ChatGPT's own runtime; a Claude instance has neither.
            if instance.appKind == .chatgpt {
                Section {
                    let locked = busy || (!instance.usesBuiltInBrowser && !store.primaryInstalled)
                    HStack(spacing: 8) {
                        ChoiceTile(badge: StatusBadge(symbol: "square.on.square", color: instance.tileColor),
                                   title: "Doppel engine",
                                   detail: "Recommended. Its own app, icon and data.",
                                   color: instance.tileColor, selected: !instance.usesBuiltInBrowser) {
                            if instance.usesBuiltInBrowser { store.releaseBuiltInBrowser() }
                        }
                        ChoiceTile(badge: StatusBadge(symbol: "lifepreserver", color: .purple),
                                   title: "Official ChatGPT",
                                   detail: "Fallback if an update breaks this clone. Same account and chats.",
                                   color: .purple, selected: instance.usesBuiltInBrowser) {
                            if !instance.usesBuiltInBrowser { store.assignBuiltInBrowser(to: instance) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .disabled(locked)
                } header: {
                    Text("Engine")
                }

                Section("Remote Access") {
                    BadgeRow(badge: StatusBadge(symbol: "iphone.and.arrow.forward", color: .blue),
                             title: "Remote Access",
                             detail: "Let another device run tasks in this account.") {
                        Button("Open…") { openWindow(id: "remote-access", value: instance.id) }
                            .disabled(busy)
                    }
                }
            }

            Section("Maintenance") {
                BadgeRow(badge: StatusBadge(symbol: "hammer.fill", color: .gray),
                         title: "Rebuild and reopen",
                         detail: "Fixes a broken clone. Keeps the account and chats.") {
                    Button("Rebuild") { store.rebuild(instance) }.disabled(busy)
                }
                if instance.appKind == .claude {
                    BadgeRow(badge: StatusBadge(symbol: "clock.arrow.circlepath", color: Design.claude),
                             title: "Import Code history",
                             detail: "Copies matching local Code sessions from the original Claude app.") {
                        Button("Import…") { store.importClaudeSessions(instance) }.disabled(busy)
                    }
                }
                BadgeRow(badge: StatusBadge(symbol: "trash.fill", color: .red),
                         title: "Remove instance",
                         detail: "The app goes to the Trash. Account data is kept unless you choose otherwise.") {
                    Button("Remove…", role: .destructive) { store.confirmRemove(instance) }
                        .disabled(busy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 680)
        .navigationTitle(instance.name)
    }

    // MARK: - Hero

    /// The instance's own tile on the dark slab, lit in its colour while it
    /// runs, with what it is and how it is doing beside it.
    private func hero(_ instance: Instance) -> some View {
        let activity = store.activity(for: instance)
        let busy = store.engineOperationBusy
        let lit = activity == .running || activity == .working
        let permissions = store.permissionStatuses.filter { $0.instanceID == instance.id && $0.permission != "permission-check" }
        let allowed = permissions.filter { $0.status == "granted" }.count
        let denied = permissions.contains { $0.needsAttention }
        var legend = [
            HeroLegend(color: Self.statusColor(activity), label: "Status", value: Self.statusText(activity)),
            HeroLegend(color: instance.appKind == .claude ? Design.claude : .white.opacity(0.7),
                       label: "App", value: instance.appKind.label),
        ]
        if instance.appKind == .chatgpt {
            legend.append(HeroLegend(color: instance.usesBuiltInBrowser ? .purple : instance.tileColor,
                                     label: "Engine",
                                     value: instance.usesBuiltInBrowser ? "Official ChatGPT" : "Doppel"))
        }
        if !permissions.isEmpty {
            legend.append(HeroLegend(color: denied ? .red : (allowed == permissions.count ? .green : Design.idle),
                                     label: "Permissions",
                                     value: "\(allowed) of \(permissions.count) allowed"))
        }
        return HeroCard(title: instance.name,
                        subtitle: (instance.appPath as NSString).abbreviatingWithTildeInPath,
                        legend: legend) {
            IconTile(color: instance.tileColor, name: instance.name, radius: 18,
                     renderingDocumentation: true, size: 76)
                .shadow(color: instance.tileColor.opacity(lit ? 0.75 : 0.0), radius: 14)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Self.statusColor(activity))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Color(white: 0.08), lineWidth: 3))
                        .offset(x: 4, y: 4)
                }
                .padding(6)
        } accessory: {
            VStack(alignment: .trailing, spacing: 8) {
                if activity == .running {
                    Button("Show") { store.show(instance) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open") { store.launch(instance) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !instance.installed)
                }
                Button("Rename…") { openWindow(id: "edit-instance", value: instance.id) }
                    .disabled(busy)
            }
            .buttonBorderShape(.capsule)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func statusColor(_ activity: InstanceActivity) -> Color {
        switch activity {
        case .running: return .green
        case .working: return .blue
        case .attention, .checkerOutdated, .notInstalled: return .red
        case .stopped: return Design.idle
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
                BadgeRow(badge: StatusBadge(symbol: permission.kindSymbol, color: Self.color(permission),
                                            muted: permission.status == "not-requested"),
                         title: permission.label,
                         detail: Self.explanation(permission),
                         detailColor: permission.needsAttention ? .red : .secondary) {
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
