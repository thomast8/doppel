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
                instanceList
            }
            Divider().padding(.horizontal, 16).padding(.top, 10)
            footer
        }
        .frame(width: 360)
    }

    /// Rows are about 54 pt. Past what fits in most of the screen the list
    /// scrolls, so the footer and the last rows stay reachable however many
    /// instances there are.
    @ViewBuilder
    private var instanceList: some View {
        let rows = VStack(spacing: 4) {
            ForEach(store.instances) { instance in row(instance) }
        }
        .padding(.horizontal, 8)
        let available = (NSScreen.main?.visibleFrame.height ?? 800) * 0.55
        let estimated = CGFloat(store.instances.count) * 58
        if estimated > available {
            ScrollView { rows }.frame(height: available)
        } else {
            rows
        }
    }

    // MARK: - Header

    /// A dark strip like the top of the Codex Micro page, with a light per
    /// instance in its colour, lit while it runs, the way the pad shows who
    /// holds each channel.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Doppel").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(spacing: 5) {
                ForEach(store.instances) { instance in
                    let lit = store.isRunning(instance)
                    Circle()
                        .fill(lit ? instance.tileColor : Design.idle)
                        .frame(width: 6, height: 6)
                        .shadow(color: lit ? instance.tileColor.opacity(0.8) : .clear, radius: 2)
                }
            }
            .padding(.leading, 6)
            .accessibilityElement()
            .accessibilityLabel("\(store.instances.filter { store.isRunning($0) }.count) of \(store.instances.count) running")
            Spacer()
            iconButton("plus", label: "New instance") { open("create-instance") }
                .disabled(store.engineOperationBusy || !store.anyAppInstalled)
            iconButton("arrow.clockwise", label: "Refresh") { store.reload() }
            iconButton("gearshape", label: "Settings") { open("settings") }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(Design.heroGradient)
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 10)
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
            checklistRow(progress.appFound, done: store.primaryInstalled && store.claudeInstalled
                         ? "ChatGPT and Claude found"
                         : (store.primaryInstalled ? "ChatGPT found" : "Claude found"),
                         todo: "Neither ChatGPT nor Claude is installed")
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
        if let error = store.lastError {
            banner(tint: .red) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Doppel could not finish that").font(.system(size: 13, weight: .semibold))
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Dismiss") { store.lastError = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        // The bar fills from the steps the CLI reports. Until the first one
        // arrives it is indeterminate under the name of the work started.
        if let note = store.progressNote {
            banner {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note).font(.system(size: 13, weight: .medium))
                    if let step = store.progress {
                        Text(step.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    progressBar(store.progress)
                    Text("You can close this panel. Doppel sends a notification when it is done.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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

    private func banner<Content: View>(tint: Color = .accentColor,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12)))
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
            .fill(rowAccent(instance, activity: activity, attention: attention)?.opacity(0.10) ?? .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(rowAccent(instance, activity: activity, attention: attention)?.opacity(0.45) ?? .clear,
                          lineWidth: 1))
    }

    /// Rows light up like the Codex Micro channel tiles: in the instance's
    /// colour while it runs, red when it needs attention, plain otherwise.
    private func rowAccent(_ instance: Instance, activity: InstanceActivity, attention: Bool) -> Color? {
        if attention { return .red }
        return activity == .running || activity == .working ? instance.tileColor : nil
    }

    @ViewBuilder
    private func statusLine(_ instance: Instance, activity: InstanceActivity) -> some View {
        switch activity {
        case .working:
            let step = store.instanceProgress[instance.id]
            VStack(alignment: .leading, spacing: 4) {
                Text(step.map { "\($0.label)…" } ?? "Working…")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                progressBar(step).controlSize(.small)
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
                if instance.appKind == .claude {
                    Text("Claude")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Design.claude.opacity(0.16)))
                        .foregroundStyle(Design.claude)
                }
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

    @ViewBuilder
    private func progressBar(_ step: CLIProgress?) -> some View {
        if let step {
            HStack(spacing: 8) {
                ProgressView(value: step.fraction).progressViewStyle(.linear)
                Text("\(Int((step.fraction * 100).rounded()))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.label), \(Int((step.fraction * 100).rounded())) percent")
        } else {
            ProgressView().progressViewStyle(.linear)
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
            Text("Each instance is its own ChatGPT or Claude app with its own account.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            pill("New instance") { open("create-instance") }
                .disabled(!store.anyAppInstalled || store.engineOperationBusy)
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
                legendDot(store.chatGPTUpdate != nil ? .blue : (store.installedChatGPT == nil ? .secondary : .green))
                Text(chatGPTLine).lineLimit(1)
                Spacer()
                Button(store.checkingForUpdates ? "Checking…" : "Check now") {
                    store.lastError = nil
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

    /// "Up to date" only after a check the CLI answered with "current"; a
    /// failed or unread check leaves the installed build from an earlier one.
    private var chatGPTLine: String {
        if store.checkingForUpdates { return "Checking for ChatGPT updates…" }
        guard let installed = store.installedChatGPT else { return "ChatGPT updates not checked yet" }
        return store.lastCheckWasCurrent && store.chatGPTUpdate == nil
            ? "ChatGPT \(installed.version) is up to date"
            : "ChatGPT \(installed.display)"
    }

    @ViewBuilder
    private var permissionLine: some View {
        let issues = store.permissionIssues
        if let first = issues.first {
            HStack(spacing: 8) {
                legendDot(.red)
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
                legendDot(.green)
                Text("Permissions OK")
            }
        }
    }

    private func legendDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).frame(width: 14)
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
            return "Running instances close, update together and reopen. Save unfinished chats first, and choose Quit if an app asks."
        case .available:
            return "Doppel downloads it from OpenAI and verifies it. Nothing closes until you restart."
        case .staleInstances:
            return "ChatGPT updated itself. Rebuilding closes the outdated instances and reopens them. Save unfinished chats first."
        }
    }

    /// The banner already names the version, so its button only says what
    /// happens next.
    static func bannerButtonTitle(_ update: ChatGPTUpdate) -> String {
        switch update.state {
        case .ready: return "Restart and Update"
        case .available: return "Download"
        case .staleInstances: return "Rebuild"
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
