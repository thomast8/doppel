import Foundation
import AppKit

enum InstanceEngine: String {
    case clone
    case vendor
}

struct Instance: Identifiable {
    let id: String        // stable slug assigned at creation
    let name: String
    let appPath: String
    let installed: Bool
    /// RRGGBB the icon was tinted with; empty for a custom .icns.
    let tint: String
    /// The profile is stable; only the process used to open it changes.
    let engine: InstanceEngine

    var usesBuiltInBrowser: Bool { engine == .vendor }
}

/// All instance knowledge comes from the CLI (`doppel list --porcelain`), so
/// the menu-bar app and the CLI cannot drift apart on config parsing.
@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var busy: Set<String> = []
    @Published var primaryInstalled = false
    @Published var signingReady = false
    @Published var chatGPTUpdate: ChatGPTUpdate?
    /// The installed vendor build, shown in the menu even when it is current.
    @Published var installedChatGPT: InstalledChatGPT?
    @Published var checkingForUpdates = false
    @Published var permissionStatuses: [PermissionIssue] = []
    @Published var checkingPermissions = false
    @Published var nativeToolsStatus: NativeToolsStatus?
    @Published var checkingNativeTools = false

    var permissionIssues: [PermissionIssue] { permissionStatuses.filter(\.needsAttention) }

    /// The last failure already reported for a given piece of work, so a
    /// condition that persists across reloads is raised once rather than after
    /// every refresh.
    private var reported: [String: String] = [:]
    /// Prompts already raised, keyed by what was offered rather than by build
    /// number alone: the reconcile prompt targets the installed build, which a
    /// download prompt for that same build may already have claimed.
    private var promptedUpdates: Set<String> = []
    /// Accessibility and Screen Recording expose only a boolean. After one
    /// native request in this app session, a still-inconclusive row falls back
    /// to its exact Settings pane instead of repeatedly raising the same flow.
    private var requestedPermissionIDs: Set<String> = []
    private var updateTimer: Timer?
    private var permissionTimer: Timer?

    static let primaryAppPath = "/Applications/ChatGPT.app"
    static let primaryDownloadURL = URL(string: "https://chatgpt.com/features/desktop/")!

    /// The CLI location. The copy inside this bundle comes first: it ships with
    /// the app, is covered by the app's signature, and means a downloaded
    /// Doppel needs no repository checkout at all.
    ///
    /// `DOPPEL_CLI` is honoured only in development mode. It used to be followed
    /// unconditionally, which made it the one environment override an installed
    /// Doppel still obeyed: pointing it elsewhere replaced the signed, bundled
    /// CLI outright, and none of the scrubbing the CLI and engine do could run
    /// because a different program was running instead. The same `DOPPEL_DEV`
    /// gate those two use applies here, and the override still has to name a
    /// binary that is not group- or world-writable.
    private var discoveredCLI: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DOPPEL_CLI"], environment["DOPPEL_DEV"] == "1" {
            if FileManager.default.isExecutableFile(atPath: override),
               !Self.isGroupOrWorldWritable(override) {
                return URL(fileURLWithPath: override)
            }
            return nil
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("doppel/bin/doppel"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("GitRepos/doppel/bin/doppel").path,
            "/opt/homebrew/bin/doppel",
            "/usr/local/bin/doppel",
        ]
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) && !Self.isGroupOrWorldWritable(candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// A CLI anyone in the admin group can replace is not one to execute
    /// silently; /opt/homebrew/bin is group-writable on many machines.
    nonisolated private static func isGroupOrWorldWritable(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attrs[.posixPermissions] as? NSNumber
        else { return true }
        return permissions.uint16Value & 0o022 != 0
    }

    init() {
        reload()
        // Check shortly after launch, then every six hours while Doppel is
        // running. The CLI performs the official-feed and signature checks;
        // the app owns only scheduling and user interaction.
        Task { [weak self] in
            // Permission health is populated first. Otherwise a prepared
            // update's modal can arrive before the menu-bar warning publishes.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            self?.checkForUpdates()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
                self?.checkNativeTools()
            }
        }
    }

    func reload() {
        primaryInstalled = FileManager.default.fileExists(atPath: Self.primaryAppPath)
        if let cli = discoveredCLI {
            signingReady = SigningIdentity.status(cli: cli).isPresent
        }
        guard let cli = discoveredCLI else {
            instances = []
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        clearReport(for: "cli")
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["list", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let message):
                    self.report(message, for: "list")
                case .success(let stdout):
                    self.clearReport(for: "list")
                    self.instances = Self.parsePorcelain(stdout).sorted { $0.name < $1.name }
                    self.checkPermissions()
                    self.checkNativeTools()
                }
            }
        }
    }

    func launch(_ instance: Instance) {
        runCLI(["launch", instance.name], busyKey: instance.id) { [weak self] failure in
            if failure == nil { self?.checkNativeTools() }
        }
    }

    func assignBuiltInBrowser(to instance: Instance) {
        runCLI(["browser", "assign", instance.name], busyKey: "iab-slot",
               reportFailure: false) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                self.reload()
                return
            }
            if Self.browserAssignmentNeedsQuit(failure) {
                self.confirmQuitAndAssignBrowser(to: instance, detail: failure)
            } else {
                self.report(failure, for: "iab-slot")
            }
        }
    }

    nonisolated static func browserAssignmentNeedsQuit(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains(
            "the Browser assignment needs running ChatGPT apps to quit")
    }

    private func confirmQuitAndAssignBrowser(to instance: Instance, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit ChatGPT and assign Browser?"
        let reason = detail
            .replacingOccurrences(of: "doppel: ", with: "")
            .replacingOccurrences(
                of: "the Browser assignment needs running ChatGPT apps to quit: ",
                with: "")
        alert.informativeText = """
            Doppel needs to close the official ChatGPT window or managed instance involved before assigning the built-in Browser to \(instance.name). Other Doppel clones will stay open.

            \(reason)

            Save any unfinished drafts before continuing.
            """
        alert.addButton(withTitle: "Quit and Assign")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard present(alert) == .alertFirstButtonReturn else { return }
        runCLI(["browser", "assign", "--quit-running", instance.name],
               busyKey: "iab-slot") { [weak self] failure in
            if failure == nil { self?.reload() }
        }
    }

    func releaseBuiltInBrowser() {
        runCLI(["browser", "release"], busyKey: "iab-slot") { [weak self] failure in
            if failure == nil { self?.reload() }
        }
    }

    func rebuild(_ instance: Instance) {
        runCLI(["rebuild", instance.name], busyKey: instance.id) { [weak self] failure in
            if failure == nil {
                self?.checkPermissions()
                self?.checkNativeTools()
            }
        }
    }

    /// Mirrors the CLI's global engine-operation lock so the menu avoids
    /// offering operations that would only be refused as concurrent work.
    var engineOperationBusy: Bool {
        busy.contains("iab-slot") || busy.contains("update") || busy.contains("signing") ||
            busy.contains("create") || instances.contains { busy.contains($0.id) }
    }

    // MARK: - Native tools

    func checkNativeTools() {
        guard !checkingNativeTools, let cli = discoveredCLI else { return }
        checkingNativeTools = true
        Task.detached { [weak self] in
            let result = Self.runProcess(
                cli: cli, arguments: ["native-tools", "status", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingNativeTools = false
                switch result {
                case .failure(let message):
                    self.report(message, for: "native-tools-status")
                case .success(let output):
                    self.clearReport(for: "native-tools-status")
                    self.nativeToolsStatus = NativeToolsStatus.parse(output)
                }
            }
        }
    }

    func repairNativeTools() {
        runCLI(["native-tools", "repair"], busyKey: "native-tools") { [weak self] failure in
            if failure == nil {
                self?.checkNativeTools()
            }
        }
    }

    // An instance that has never run has no browser extension host of its own
    // to point at, and the CLI refuses rather than writing a dangling path. Its
    // refusal explains what to do, so it is surfaced as-is.
    /// Passing a browser assigns just that one, so two instances can hold two
    /// different browsers at once. Omitting it assigns every registration.
    func claimBrowserHost(for instance: Instance, browser: String? = nil) {
        var arguments = ["native-tools", "claim-browser"]
        if let browser { arguments += ["--browser", browser] }
        arguments.append(instance.name)
        runCLI(arguments, busyKey: "native-tools") { [weak self] _ in
            self?.checkNativeTools()
        }
    }

    // MARK: - Permission health

    func checkPermissions() {
        guard !checkingPermissions, !busy.contains("permissions"), let cli = discoveredCLI else { return }
        checkingPermissions = true
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["permissions", "check", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingPermissions = false
                switch result {
                case .failure(let message):
                    self.report(message, for: "permissions-check")
                case .success(let output):
                    self.clearReport(for: "permissions-check")
                    self.permissionStatuses = PermissionIssue.parseStatuses(output)
                }
            }
        }
    }

    func showPermissionIssues() {
        guard !permissionIssues.isEmpty else { return }
        showPermissionIssues(permissionIssues)
    }

    private func showPermissionIssues(_ issues: [PermissionIssue]) {
        let grouped = Dictionary(grouping: issues, by: \.instanceName)
        let details = grouped.keys.sorted().map { name in
            let labels = grouped[name, default: []].map(\.label).sorted().joined(separator: ", ")
            return "• \(name): \(labels)"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = issues.count == 1
            ? "A managed ChatGPT permission needs attention"
            : "Managed ChatGPT permissions need attention"
        alert.informativeText = """
            macOS reports an explicit denial or an outdated permission checker for:

            \(details)

            Open the exact permission from an instance's Privacy Permissions submenu. Doppel no longer treats unused or unconfirmable capabilities as errors.
            """
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    func handlePermission(_ permission: PermissionIssue) {
        switch permission.action {
        case .requestNative where !requestedPermissionIDs.contains(permission.id):
            if permission.nativeRequestCanStayInconclusive {
                requestedPermissionIDs.insert(permission.id)
            }
            runCLI(
                ["permissions", "request", permission.instanceName, permission.permission],
                busyKey: "permissions"
            ) { [weak self] failure in
                guard let self else { return }
                if failure == nil {
                    self.checkPermissions()
                } else {
                    self.requestedPermissionIDs.remove(permission.id)
                }
            }
        case .requestNative, .openSettings:
            openPermissionSettings(permission)
        case .unavailable:
            break
        }
    }

    private func openPermissionSettings(_ permission: PermissionIssue) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Coordinated ChatGPT updates

    func checkForUpdates(userInitiated: Bool = false) {
        guard !checkingForUpdates, !busy.contains("update") else { return }
        guard let cli = discoveredCLI else {
            if userInitiated { report(Self.missingCLIMessage, for: "cli") }
            return
        }
        checkingForUpdates = true
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["update", "check", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingForUpdates = false
                switch result {
                case .failure(let message):
                    // A background check must stay quiet when the Mac is
                    // offline. A check the user explicitly requested reports
                    // the same actionable CLI failure.
                    if userInitiated { self.report(message, for: "update-check") }
                case .success(let output):
                    self.clearReport(for: "update-check")
                    // Recorded whether or not there is an update to offer, so
                    // the menu can show the installed build either way.
                    self.installedChatGPT = InstalledChatGPT.parse(output)
                    guard let update = ChatGPTUpdate.parse(output) else {
                        self.chatGPTUpdate = nil
                        // Only the CLI saying "current" means current. A line
                        // this version cannot read — a state word added by a
                        // newer CLI than the app, which the dev-mode CLI
                        // lookup makes possible — used to be announced as
                        // being up to date, which is the one thing it does not
                        // prove.
                        if userInitiated {
                            if Self.resultFields(output).first == "current" {
                                self.showCurrentAlert()
                            } else {
                                self.report(Self.unreadableUpdateCheckMessage, for: "update-check")
                            }
                        }
                        return
                    }
                    self.chatGPTUpdate = update
                    self.promptForUpdate(update, force: userInitiated)
                }
            }
        }
    }

    func beginKnownUpdate() {
        guard let update = chatGPTUpdate else {
            checkForUpdates(userInitiated: true)
            return
        }
        promptForUpdate(update, force: true)
    }

    /// True the first time a given prompt is offered for a given build, and
    /// whenever the user asked for it themselves. Keyed by the state that
    /// produced the prompt, so a reconcile offer for the installed build is not
    /// suppressed by an earlier download offer that happened to name the same
    /// number.
    private func shouldPrompt(_ update: ChatGPTUpdate, force: Bool) -> Bool {
        let key = "\(update.state.rawValue)-\(update.targetBuild)"
        guard force || !promptedUpdates.contains(key) else { return false }
        promptedUpdates.insert(key)
        return true
    }

    private func promptForUpdate(_ update: ChatGPTUpdate, force: Bool = false) {
        switch update.state {
        case .ready:
            promptToRestart(update, force: force)
            return
        case .staleInstances:
            promptToReconcile(update, force: force)
            return
        case .available:
            break
        }
        guard shouldPrompt(update, force: force) else { return }
        let alert = updateAlert()
        alert.messageText = "A new version of ChatGPT is available!"
        alert.informativeText = """
            ChatGPT \(update.targetVersion) is now available—you have \(update.currentVersion). Would you like to download it now?

            Doppel will apply this update to the primary app and all \(instances.filter(\.installed).count) managed instances together.
            """
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Remind Me Later")
        guard present(alert) == .alertFirstButtonReturn else { return }
        prepareUpdate(update)
    }

    private func prepareUpdate(_ update: ChatGPTUpdate) {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("update")
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["update", "prepare"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove("update")
                switch result {
                case .failure(let message):
                    self.report(message, for: "update")
                case .success(let output):
                    self.clearReport(for: "update")
                    // `update prepare` also succeeds with "already current"
                    // when the vendor's own updater installed the build while
                    // Doppel was downloading it. Offering "Restart and Install"
                    // on that would apply a build the primary already has, so
                    // the state is re-read instead of assumed.
                    guard Self.resultFields(output).first == "ready" else {
                        self.chatGPTUpdate = nil
                        self.checkForUpdates(userInitiated: true)
                        return
                    }
                    let ready = ChatGPTUpdate(
                        state: .ready,
                        currentBuild: update.currentBuild,
                        currentVersion: update.currentVersion,
                        targetBuild: update.targetBuild,
                        targetVersion: update.targetVersion,
                        staleInstanceCount: 0)
                    self.chatGPTUpdate = ready
                    self.promptToRestart(ready, force: true)
                }
            }
        }
    }

    /// The last line of a CLI result, split into its tab-separated fields. The
    /// outcome word is always the final line, so a progress note printed ahead
    /// of it cannot be read as one.
    nonisolated static func resultFields(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "\n").last else { return [] }
        return last.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    /// Offered when ChatGPT's own updater moved the primary on its own: the
    /// instances are the only thing left behind, and they are rebuilt from the
    /// app already installed.
    private func promptToReconcile(_ update: ChatGPTUpdate, force: Bool = false) {
        guard shouldPrompt(update, force: force) else { return }
        let count = update.staleInstanceCount
        let noun = count == 1 ? "instance" : "instances"
        let alert = updateAlert()
        alert.messageText = "Managed Instances Are Out of Date"
        alert.informativeText = """
            ChatGPT updated itself to \(update.targetVersion) outside Doppel, so \(count) managed \(noun) \(count == 1 ? "is" : "are") still running an older version.

            Doppel will close \(count == 1 ? "that instance" : "those instances"), rebuild \(count == 1 ? "it" : "them") from the installed ChatGPT app, then reopen only the ones you were using. The primary ChatGPT app is not touched and nothing needs downloading.

            Active local chats will be interrupted. If a managed app asks you to confirm quitting, choose Quit so Doppel can continue safely.
            """
        alert.addButton(withTitle: "Rebuild \(count == 1 ? "Instance" : "Instances")")
        alert.addButton(withTitle: "Later")
        guard present(alert) == .alertFirstButtonReturn else { return }
        applyUpdate(update)
    }

    private func promptToRestart(_ update: ChatGPTUpdate, force: Bool = false) {
        guard shouldPrompt(update, force: force) else { return }
        let alert = updateAlert()
        alert.messageText = "Ready to Install"
        alert.informativeText = """
            ChatGPT \(update.targetVersion) has been downloaded and verified.

            Doppel will close every running managed instance, update the primary ChatGPT app, rebuild and verify all managed instances, then reopen only the ones you were using.

            A profile using Built-in Browser is closed and reopened through the official app on that same profile. If an official ChatGPT window is open on some other profile, or more than one is open, Doppel stops before changing any app.

            Active local chats will be interrupted. If a managed app asks you to confirm quitting, choose Quit so Doppel can continue safely.
            """
        alert.addButton(withTitle: "Restart and Install")
        alert.addButton(withTitle: "Later")
        guard present(alert) == .alertFirstButtonReturn else { return }
        applyUpdate(update)
    }

    private func applyUpdate(_ update: ChatGPTUpdate) {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("update")
        Task.detached { [weak self] in
            let result = Self.runProcess(
                cli: cli, arguments: ["update", "apply", String(update.targetBuild)])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove("update")
                switch result {
                case .failure(let message):
                    self.report(message, for: "update")
                    // The cached offer is what was just refused. Keeping it
                    // would let the same doomed apply be retried from the menu;
                    // re-reading is also how a primary that moved underneath
                    // Doppel turns into the reconcile offer that fixes it.
                    self.chatGPTUpdate = nil
                    self.checkForUpdates()
                case .success(let output):
                    self.clearReport(for: "update")
                    self.chatGPTUpdate = nil
                    self.reload()
                    self.showUpdateComplete(update, output: output)
                }
            }
        }
    }

    private func updateAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let icon = NSWorkspace.shared.icon(forFile: Self.primaryAppPath)
        icon.size = NSSize(width: 64, height: 64)
        alert.icon = icon
        return alert
    }

    /// Presents an alert so it is actually seen. Activation is cooperative on
    /// macOS 14+: a menu-bar app raising a modal from a timer or a finished
    /// background task can be denied, which leaves the alert behind the
    /// frontmost app or off the user's full-screen Space — a "Ready to
    /// Install" prompt nobody sees reads as the updater doing nothing.
    /// Ordering the panel front regardless and letting it join the active
    /// Space keeps it visible; it takes keyboard focus only when macOS grants
    /// activation, so it can't swallow keystrokes meant for another app.
    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let window = alert.window
        // runModal does not reliably raise the panel to modal level under the
        // SwiftUI lifecycle; left at .normal, an inactive menu-bar app's alert
        // sits behind the frontmost app's windows. canJoinAllSpaces rather
        // than moveToActiveSpace: the alert pins to whichever Space is active
        // the moment it appears, and the user may have switched by then.
        window.level = .modalPanel
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.orderFrontRegardless()
        return alert.runModal()
    }

    private func showCurrentAlert() {
        let alert = updateAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "ChatGPT and its managed Doppel instances are using the latest available version."
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    private func showUpdateComplete(_ update: ChatGPTUpdate, output: String) {
        let fields = Self.resultFields(output)
        let outcome = fields.first ?? "updated"
        let verified = fields.count > 3 ? fields[3] : "all"
        let reopened = fields.count > 4 ? fields[4] : "all previously running"
        let alert = updateAlert()
        let signingNote = signingReady ? "" : """

            This Mac is using ad-hoc signing, so macOS may have forgotten permissions for the rebuilt apps. Doppel will show one menu-bar warning if anything needs attention. Set Up Secure Signing before the next update to preserve their code identity.
            """
        // A reconcile installs nothing, so saying an update was installed would
        // be a claim the run never made.
        switch outcome {
        case "reconciled":
            alert.messageText = "Instances Rebuilt"
            alert.informativeText = """
                Doppel rebuilt \(verified) managed instance(s) from ChatGPT \(update.targetVersion) and reopened \(reopened).
                \(signingNote)
                """
        case "current":
            // Deliberately not a claim about all N instances: the count is
            // every installed instance, and one of them can be ahead of the
            // primary rather than matching it.
            alert.messageText = "Nothing to Rebuild"
            alert.informativeText = """
                No managed instance needed rebuilding for ChatGPT \(update.targetVersion), so nothing was changed or closed.
                """
        default:
            alert.messageText = "Update Complete"
            alert.informativeText = """
                ChatGPT \(update.targetVersion) is installed.

                Doppel verified \(verified) managed instance(s) and reopened \(reopened).
                \(signingNote)
                """
        }
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    /// Creates an instance from just a name and a tint color; the CLI derives
    /// bundle id, URL scheme, and data directories from the name.
    func create(name: String, tintHex: String, completion: @escaping (String?) -> Void) {
        let tintArguments = tintHex == "original" ? ["--original-icon"] : ["--tint", tintHex]
        // As with edit: the window is still on screen and shows the failure
        // itself.
        runCLI(["create", "--name", name] + tintArguments, busyKey: "create",
               reportFailure: false) { [weak self] failure in
            if failure == nil { self?.reload() }
            completion(failure)
        }
    }

    /// Renames an instance and/or changes its tint. Identity and account data
    /// are fixed at creation, so neither is touched here.
    func edit(_ instance: Instance, newName: String?, tintHex: String?,
              completion: @escaping (String?) -> Void) {
        var arguments = ["edit", instance.name]
        if let newName, newName != instance.name { arguments += ["--rename", newName] }
        if let tintHex {
            arguments += tintHex == "original" ? ["--original-icon"] : ["--tint", tintHex]
        }
        guard arguments.count > 2 else { completion(nil); return }
        // The edit window shows its own failure inline, so this one is not
        // raised as an alert on top of it.
        runCLI(arguments, busyKey: instance.id, reportFailure: false) { [weak self] failure in
            if failure == nil { self?.reload() }
            completion(failure)
        }
    }

    /// Removes an instance. The CLI moves the app to the Trash and keeps the
    /// instance definition; account data is only touched with purgeData.
    func remove(_ instance: Instance, purgeData: Bool) {
        var arguments = ["remove", instance.name]
        if purgeData { arguments.append("--purge-data") }
        runCLI(arguments, busyKey: instance.id) { [weak self] failure in
            if failure == nil { self?.reload() }
        }
    }

    /// Creates the local signing identity, then rebuilds every instance so
    /// they adopt it — the rebuild is the half users would otherwise forget.
    func setUpSigning() {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("signing")
        let instanceNames = instances.map(\.name)
        Task.detached { [weak self] in
            let failure = SigningIdentity.setUp(cli: cli)
            if failure == nil {
                for name in instanceNames {
                    _ = Self.runProcess(cli: cli, arguments: ["rebuild", name])
                }
            }
            await MainActor.run { [weak self] in
                self?.busy.remove("signing")
                if let failure { self?.report(failure, for: "signing") }
                self?.reload()
            }
        }
    }

    var loginItemEnabled: Bool { LoginItem.isEnabled }

    func setLoginItem(_ enabled: Bool) {
        if let failure = LoginItem.setEnabled(enabled) {
            report(failure, for: "login")
        }
        objectWillChange.send()
    }

    // MARK: - Reporting failures

    static let missingCLIMessage = "The doppel command-line tool could not be found. Reinstall Doppel, or for a build from source set DOPPEL_DEV=1 and DOPPEL_CLI to its path."

    static let unreadableUpdateCheckMessage = "Doppel could not understand what the doppel command-line tool reported about updates, so it cannot say whether anything needs updating. Update Doppel, or run 'doppel update check' in Terminal to see the answer directly."

    /// Failures are raised as an alert when they happen. The menu stays a list
    /// of instances and the things you can do to them — never a log of what
    /// went wrong earlier, which outlived the problem it described and kept
    /// describing it long after the user had moved on.
    private func report(_ message: String, for key: String) {
        guard reported[key] != message else { return }
        reported[key] = message
        let alert = NSAlert()
        alert.messageText = "Doppel could not finish that"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    private func clearReport(for key: String) {
        reported[key] = nil
    }

    nonisolated static func parsePorcelain(_ output: String) -> [Instance] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            // Tint and engine were added later; older output stays readable
            // and defaults to the historical locally signed engine.
            guard fields.count >= 4 else { return nil }
            return Instance(
                id: String(fields[0]),
                name: String(fields[1]),
                appPath: String(fields[2]),
                installed: fields[3] == "installed",
                tint: fields.count > 4 ? String(fields[4]) : "",
                engine: fields.count > 5
                    ? InstanceEngine(rawValue: String(fields[5])) ?? .clone
                    : .clone
            )
        }
    }

    nonisolated private static func runProcess(cli: URL, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [cli.path] + arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                // Fall back through stderr, then stdout: a bare "exited 1" tells
                // the user nothing about what actually went wrong.
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = !stderr.isEmpty
                    ? stderr
                    : stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(detail.isEmpty
                                ? "doppel exited \(process.terminationStatus)"
                                : detail)
            }
            return .success(stdout)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// reportFailure is false for the work the create/edit window drives: that
    /// window is still on screen and shows the message itself.
    private func runCLI(_ arguments: [String], busyKey: String,
                        reportFailure: Bool = true,
                        completion: (@MainActor (String?) -> Void)? = nil) {
        guard let cli = discoveredCLI else {
            if reportFailure { report(Self.missingCLIMessage, for: "cli") }
            completion?(Self.missingCLIMessage)
            return
        }
        busy.insert(busyKey)
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: arguments)
            let failure: String?
            if case .failure(let message) = result { failure = message } else { failure = nil }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(busyKey)
                if let failure {
                    if reportFailure { self.report(failure, for: busyKey) }
                } else {
                    self.clearReport(for: busyKey)
                }
                completion?(failure)
            }
        }
    }
}

/// Swift's Result requires Failure: Error; a plain enum is simpler here.
enum ProcessResult {
    case success(String)
    case failure(String)
}
