import SwiftUI
import AppKit

/// Panel-only state that is not the store's business: which update offer the
/// user has put off for this session.
final class PanelModel: ObservableObject {
    @Published var dismissedUpdateKey: String?
}

extension ChatGPTUpdate {
    var offerKey: String { "\(state.rawValue)-\(targetBuild)" }
}

extension Instance {
    /// Custom artwork has no tint to show, so it reads as a neutral tile.
    var tileColor: Color {
        tint.isEmpty || tint == "original" ? Color(white: 0.62) : Color(hex: tint)
    }
}

/// The window-style menu bar extra stays open when another window comes
/// forward, which leaves it covering the window it just opened. There is no
/// public dismiss on macOS 14, so the panel's own window is closed directly.
@MainActor
enum PanelWindow {
    static func close() {
        for window in NSApp.windows
        where String(describing: type(of: window)).contains("MenuBarExtra") && window.isVisible {
            window.close()
        }
    }

    static func bringForward(_ open: () -> Void) {
        close()
        open()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu bar panel: every instance with its state and one action, and
/// below them the two things that need the user's attention from time to time,
/// ChatGPT updates and permissions. Everything else lives in the instance
/// window or Settings.
struct MenuContent: View {
    @ObservedObject var store: InstanceStore
    @ObservedObject var updaterController: DoppelUpdater
    let doppelUpdatesEnabled: Bool
    @StateObject private var panel = PanelModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !store.setupProgress.isComplete { setupCard }
            updateBanner
            if store.instances.isEmpty {
                emptyState
            } else {
                Text("Instances")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                // ponytail: no scrolling; a Mac with more than a dozen
                // instances would want a ScrollView with a measured height.
                VStack(spacing: 2) {
                    ForEach(store.instances) { instance in row(instance) }
                }
                .padding(.horizontal, 8)
            }
            Divider().padding(.horizontal, 16).padding(.top, 10)
            footer
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Doppel").font(.system(size: 15, weight: .semibold))
            Spacer()
            iconButton("plus", label: "New instance") { open("create-instance") }
                .disabled(store.engineOperationBusy || !store.primaryInstalled)
            iconButton("arrow.clockwise", label: "Refresh") { store.reload() }
            iconButton("gearshape", label: "Settings") { open("settings") }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func iconButton(_ symbol: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Setup checklist

    private var setupCard: some View {
        let progress = store.setupProgress
        return VStack(alignment: .leading, spacing: 8) {
            Text("Finish setting up").font(.system(size: 13, weight: .semibold))
            checklistRow(progress.chatGPTFound, done: "ChatGPT found", todo: "ChatGPT is not installed")
            checklistRow(progress.signingReady, done: "Secure signing ready", todo: "Secure signing not set up")
            checklistRow(progress.hasInstance, done: "First instance created", todo: "No instance yet")
            HStack {
                Spacer()
                Button("Continue setup") { open("onboarding") }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.orange.opacity(0.13)))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func checklistRow(_ isDone: Bool, done: String, todo: String) -> some View {
        Label {
            Text(isDone ? done : todo)
        } icon: {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? Color.green : Color.orange)
        }
        .font(.system(size: 12.5))
    }

    // MARK: - Update banner

    private var visibleUpdate: ChatGPTUpdate? {
        guard let update = store.chatGPTUpdate, update.offerKey != panel.dismissedUpdateKey else { return nil }
        return update
    }

    @ViewBuilder
    private var updateBanner: some View {
        if store.busy.contains("update") {
            banner {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Updating ChatGPT and its instances…").font(.system(size: 13, weight: .medium))
                }
            }
        } else if let update = visibleUpdate {
            banner {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.updateHeadline(update)).font(.system(size: 13, weight: .semibold))
                            Text(Self.updateDetail(update))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
                    }
                    HStack {
                        Spacer()
                        Button("Later") { panel.dismissedUpdateKey = update.offerKey }
                            .buttonStyle(.bordered)
                        // The confirmation alert stays: it is where the
                        // interruption is spelled out before anything closes.
                        Button(Self.bannerButtonTitle(update)) { store.beginKnownUpdate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.engineOperationBusy)
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.12)))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }

    // MARK: - Instances

    private func row(_ instance: Instance) -> some View {
        let activity = store.activity(for: instance)
        let attention: Bool = {
            switch activity {
            case .attention, .checkerOutdated: return true
            default: return false
            }
        }()
        return HStack(spacing: 11) {
            IconTile(color: instance.tileColor, name: instance.name, radius: 9,
                     renderingDocumentation: true, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(instance.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusLine(instance, activity: activity)
            }
            Spacer(minLength: 4)
            rowAction(instance, activity: activity)
            Button {
                open("instance", value: instance.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Instance details")
            .accessibilityLabel("\(instance.name) details")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(attention ? Color.red.opacity(0.10) : Color.clear))
    }

    @ViewBuilder
    private func statusLine(_ instance: Instance, activity: InstanceActivity) -> some View {
        switch activity {
        case .working:
            VStack(alignment: .leading, spacing: 4) {
                Text("Working…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
        case .checkerOutdated:
            Label("Permission checker needs a rebuild", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .lineLimit(1)
        case .attention(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .lineLimit(1)
        case .running, .stopped, .notInstalled:
            HStack(spacing: 6) {
                Circle()
                    .fill(activity == .running ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(activity == .running ? "Running"
                     : (activity == .stopped ? "Not running" : "App missing, rebuild it"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if instance.usesBuiltInBrowser {
                    Text("Official engine")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    @ViewBuilder
    private func rowAction(_ instance: Instance, activity: InstanceActivity) -> some View {
        switch activity {
        case .working:
            EmptyView()
        case .attention:
            pill("Fix…") { open("instance", value: instance.id) }
        case .notInstalled, .checkerOutdated:
            pill("Rebuild") { store.rebuild(instance) }.disabled(store.engineOperationBusy)
        case .running:
            pill("Show") { PanelWindow.close(); store.show(instance) }
        case .stopped:
            pill("Open") { PanelWindow.close(); store.launch(instance) }
                .disabled(store.engineOperationBusy)
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<2) { _ in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, height: 34)
                }
            }
            .accessibilityHidden(true)
            Text("No instances yet").font(.system(size: 14, weight: .semibold))
            Text("Each instance is its own ChatGPT app with its own account.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            pill("New instance") { open("create-instance") }
                .disabled(!store.primaryInstalled || store.engineOperationBusy)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text(chatGPTLine).lineLimit(1)
                Spacer()
                Button(store.checkingForUpdates ? "Checking…" : "Check now") {
                    store.checkForUpdates(userInitiated: true)
                }
                .buttonStyle(.link)
                .disabled(store.checkingForUpdates || store.busy.contains("update"))
            }
            permissionLine
            HStack {
                Text(Self.doppelVersionLabel)
                Spacer()
                Button("Quit Doppel") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// Only the installed build is claimed. "Up to date" would need a check
    /// that answered "current", and a failed or unread check leaves this value
    /// from an earlier one.
    private var chatGPTLine: String {
        if store.checkingForUpdates { return "Checking for ChatGPT updates…" }
        guard let installed = store.installedChatGPT else { return "ChatGPT updates not checked yet" }
        return "ChatGPT \(installed.display)"
    }

    @ViewBuilder
    private var permissionLine: some View {
        let issues = store.permissionIssues
        if let first = issues.first {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                Text(issues.count == 1 ? "1 permission needs attention"
                     : "\(issues.count) permissions need attention")
                Spacer()
                Button("Review") { open("instance", value: first.instanceID) }.buttonStyle(.link)
            }
        } else if store.checkingPermissions && store.permissionStatuses.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Checking permissions…").foregroundStyle(.secondary)
            }
        } else if !store.permissionStatuses.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("Permissions OK")
            }
        }
    }

    private func open(_ id: String) {
        PanelWindow.bringForward { openWindow(id: id) }
    }

    private func open(_ id: String, value: String) {
        PanelWindow.bringForward { openWindow(id: id, value: value) }
    }

    // MARK: - Copy

    static func updateHeadline(_ update: ChatGPTUpdate) -> String {
        switch update.state {
        case .ready: return "ChatGPT \(update.targetVersion) is ready to install"
        case .available: return "ChatGPT \(update.targetVersion) is available"
        case .staleInstances:
            return update.staleInstanceCount == 1
                ? "1 instance is out of date"
                : "\(update.staleInstanceCount) instances are out of date"
        }
    }

    static func updateDetail(_ update: ChatGPTUpdate) -> String {
        switch update.state {
        case .ready:
            return "Running instances close, update together and reopen."
        case .available:
            return "Doppel downloads it from OpenAI and updates every instance together."
        case .staleInstances:
            return "ChatGPT updated itself. A rebuild brings the instances back in line."
        }
    }

    /// The banner already names the version, so its button only says what
    /// happens next.
    static func bannerButtonTitle(_ update: ChatGPTUpdate) -> String {
        switch update.state {
        case .ready: return "Restart and Update…"
        case .available: return "Download…"
        case .staleInstances: return "Rebuild…"
        }
    }

    /// What the one update button offers. A stale-instance row is not an
    /// available version: nothing is downloaded and the primary is left alone,
    /// so offering to install a version the Mac already has would misdescribe
    /// the work.
    static func updateButtonTitle(_ update: ChatGPTUpdate) -> String {
        switch update.state {
        case .ready:
            return "Restart to Install ChatGPT \(update.targetVersion)…"
        case .available:
            return "Install ChatGPT \(update.targetVersion)…"
        case .staleInstances:
            let noun = update.staleInstanceCount == 1 ? "Instance" : "Instances"
            return "Rebuild \(update.staleInstanceCount) Outdated \(noun)…"
        }
    }

    /// Doppel's own marketing version and build, from the bundle it is running
    /// out of.
    static let doppelVersionLabel: String = versionLabel(
        short: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)

    /// Split from the bundle lookup so the formatting is testable. A build from
    /// source with missing or blank version keys still has to read sensibly
    /// rather than showing "Doppel  ()".
    static func versionLabel(short: String?, build: String?) -> String {
        func cleaned(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        switch (cleaned(short), cleaned(build)) {
        case let (short?, build?): return "Doppel \(short) (\(build))"
        case let (short?, .none): return "Doppel \(short)"
        case let (.none, build?): return "Doppel build \(build)"
        case (.none, .none): return "Doppel (version unknown)"
        }
    }
}
