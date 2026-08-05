import Foundation
import AppKit

struct Instance: Identifiable {
    let id: String        // stable slug assigned at creation
    let name: String
    let appPath: String
    let installed: Bool
    /// RRGGBB the icon was tinted with; empty for a custom .icns.
    let tint: String
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
    @Published var checkingForUpdates = false
    @Published var permissionStatuses: [PermissionIssue] = []
    @Published var checkingPermissions = false

    var permissionIssues: [PermissionIssue] { permissionStatuses.filter(\.needsAttention) }

    /// The last failure already reported for a given piece of work, so a
    /// condition that persists across reloads is raised once rather than after
    /// every refresh.
    private var reported: [String: String] = [:]
    private var promptedUpdateBuilds: Set<Int> = []
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
    private var discoveredCLI: URL? {
        if let override = ProcessInfo.processInfo.environment["DOPPEL_CLI"] {
            return URL(fileURLWithPath: override)
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
            Task { @MainActor in self?.checkPermissions() }
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
                }
            }
        }
    }

    func launch(_ instance: Instance) {
        runCLI(["launch", instance.name], busyKey: instance.id)
    }

    func rebuild(_ instance: Instance) {
        runCLI(["rebuild", instance.name], busyKey: instance.id) { [weak self] failure in
            if failure == nil { self?.checkPermissions() }
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
            requestedPermissionIDs.insert(permission.id)
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
                    guard let update = ChatGPTUpdate.parse(output) else {
                        self.chatGPTUpdate = nil
                        if userInitiated { self.showCurrentAlert() }
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
        if update.state == .ready {
            promptToRestart(update, force: true)
        } else {
            promptForUpdate(update, force: true)
        }
    }

    private func promptForUpdate(_ update: ChatGPTUpdate, force: Bool = false) {
        if update.state == .ready {
            promptToRestart(update, force: force)
            return
        }
        guard force || !promptedUpdateBuilds.contains(update.targetBuild) else { return }
        promptedUpdateBuilds.insert(update.targetBuild)
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
                case .success:
                    self.clearReport(for: "update")
                    let ready = ChatGPTUpdate(
                        state: .ready,
                        currentBuild: update.currentBuild,
                        currentVersion: update.currentVersion,
                        targetBuild: update.targetBuild,
                        targetVersion: update.targetVersion)
                    self.chatGPTUpdate = ready
                    self.promptToRestart(ready, force: true)
                }
            }
        }
    }

    private func promptToRestart(_ update: ChatGPTUpdate, force: Bool = false) {
        guard force || !promptedUpdateBuilds.contains(-update.targetBuild) else { return }
        promptedUpdateBuilds.insert(-update.targetBuild)
        let alert = updateAlert()
        alert.messageText = "Ready to Install"
        alert.informativeText = """
            ChatGPT \(update.targetVersion) has been downloaded and verified.

            Doppel will close every running managed instance, update the primary ChatGPT app, rebuild and verify all managed instances, then reopen only the ones you were using.

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
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        let verified = fields.count > 3 ? fields[3] : "all"
        let reopened = fields.count > 4 ? fields[4] : "all previously running"
        let alert = updateAlert()
        alert.messageText = "Update Complete"
        let signingNote = signingReady ? "" : """

            This Mac is using ad-hoc signing, so macOS may have forgotten permissions for the rebuilt apps. Doppel will show one menu-bar warning if anything needs attention. Set Up Secure Signing before the next update to preserve their code identity.
            """
        alert.informativeText = """
            ChatGPT \(update.targetVersion) is installed.

            Doppel verified \(verified) managed instance(s) and reopened \(reopened).
            \(signingNote)
            """
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

    static let missingCLIMessage = "The doppel command-line tool could not be found. Set DOPPEL_CLI to its path."

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

    nonisolated private static func parsePorcelain(_ output: String) -> [Instance] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            // The tint field was added later; older output stays readable.
            guard fields.count >= 4 else { return nil }
            return Instance(
                id: String(fields[0]),
                name: String(fields[1]),
                appPath: String(fields[2]),
                installed: fields[3] == "installed",
                tint: fields.count > 4 ? String(fields[4]) : ""
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
