import Foundation
import AppKit

enum InstanceEngine: String {
    case clone
    case vendor
}

enum InstanceApp: String, CaseIterable, Hashable, Sendable {
    case chatgpt, claude

    var label: String { self == .chatgpt ? "ChatGPT" : "Claude" }
    var cliPrefix: [String] { self == .chatgpt ? [] : ["--app", "claude"] }
    var path: String { "/Applications/\(label).app" }
    var downloadURL: URL {
        URL(string: self == .chatgpt ? "https://chatgpt.com/features/desktop/" : "https://claude.com/download")!
    }
    func instanceID(_ slug: String) -> String { self == .chatgpt ? slug : "claude/\(slug)" }
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
    var appKind: InstanceApp = .chatgpt

    var usesBuiltInBrowser: Bool { engine == .vendor }
}

extension InstanceStore {
    /// Whether the app an instance is built from is on this Mac.
    func isInstalled(_ kind: InstanceApp) -> Bool {
        kind == .chatgpt ? primaryInstalled : claudeInstalled
    }

    var anyAppInstalled: Bool { primaryInstalled || claudeInstalled }
}

/// All instance knowledge comes from the CLI (`doppel list --porcelain`), so
/// the menu-bar app and the CLI cannot drift apart on config parsing.
@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var busy: Set<String> = []
    @Published var primaryInstalled = false
    @Published var claudeInstalled = false
    @Published var signingReady = false
    @Published var chatGPTUpdate: ChatGPTUpdate?
    /// The installed vendor build, shown in the menu even when it is current.
    @Published var installedChatGPT: InstalledChatGPT?
    @Published var checkingForUpdates = false
    @Published var permissionStatuses: [PermissionIssue] = []
    @Published var checkingPermissions = false
    @Published var nativeToolsStatus: NativeToolsStatus?
    @Published var checkingNativeTools = false
    @Published var creatorMicroOwnerID: String?
    @Published var checkingCreatorMicro = false
    @Published var creatorMicroStatusAvailable = false
    /// Who holds each of the pad's Bluetooth channels.
    @Published var microChannels = MicroChannels()
    /// What setting up Claude Code on a channel would change, shown on the
    /// Codex Micro page until it is applied or cancelled.
    @Published var claudeMicroPlan: ClaudeMicroPlan?
    /// False until the CLI has answered once, so an empty list at launch is
    /// not mistaken for a Mac with no instances.
    @Published var listLoaded = false
    /// True only after a check that the CLI answered with "current".
    @Published var lastCheckWasCurrent = false
    /// What long-running work is doing, for the panel's progress banner.
    @Published var progressNote: String?
    /// The latest step the CLI reported for that work, when it reports any.
    @Published var progress: CLIProgress?
    /// The same for single-instance work such as a rebuild, keyed by slug.
    @Published var instanceProgress: [String: CLIProgress] = [:]
    /// The most recent failure, kept in the panel until dismissed so it is
    /// still there for someone who missed the notification.
    @Published var lastError: String?
    /// Bundle paths of every running app, kept current from NSWorkspace so the
    /// panel can say which clones are open without asking the CLI.
    @Published var runningAppPaths: [String] = []
    private var remoteProcesses: [UUID: RemoteCLIProcess] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    var permissionIssues: [PermissionIssue] { permissionStatuses.filter(\.needsAttention) }

    var setupProgress: SetupProgress {
        SetupProgress(appFound: primaryInstalled || claudeInstalled, signingReady: signingReady,
                      hasInstance: !instances.isEmpty)
    }

    /// A vendor-engine instance runs inside official ChatGPT, whose bundle path
    /// says nothing about the profile; the native-tools receipt does.
    func isRunning(_ instance: Instance) -> Bool {
        if instance.usesBuiltInBrowser {
            guard let status = nativeToolsStatus else { return false }
            return status.inAppBrowserRunning && status.inAppBrowserInstanceID == instance.id
        }
        return runningAppPaths.contains { Self.pathsMatch($0, instance.appPath) }
    }

    func activity(for instance: Instance) -> InstanceActivity {
        InstanceActivity.derive(
            installed: instance.installed,
            busy: busy.contains(instance.id),
            issues: permissionStatuses.filter { $0.instanceID == instance.id },
            running: isRunning(instance))
    }

    nonisolated static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private func refreshRunningApps() {
        runningAppPaths = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
    }

    private func observeRunningApps() {
        refreshRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunningApps() }
            })
        }
    }

    /// The last failure already reported for a given piece of work, so a
    /// condition that persists across reloads is raised once rather than after
    /// every refresh.
    private var reported: [String: String] = [:]
    /// Prompts already raised, keyed by what was offered rather than by build
    /// number alone: the reconcile prompt targets the installed build, which a
    /// download prompt for that same build may already have claimed.
    private var announcedUpdates: Set<String> = []
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

    /// Starts a Remote Access CLI command without passing profile data through
    /// a shell. Output is delivered one line at a time; callers must ignore
    /// stdout for commands that can emit secrets (notably export-key).
    @discardableResult
    func runRemoteCLI(_ arguments: [String], timeout: TimeInterval = 300,
                      onLine: @escaping @MainActor (String) -> Void = { _ in },
                      completion: @escaping @MainActor (Result<String, Error>) -> Void) -> RemoteCLIProcess? {
        guard let cli = discoveredCLI else {
            completion(.failure(RemoteCLIError("Doppel CLI is unavailable.")))
            return nil
        }
        let id = UUID()
        let operation = RemoteCLIProcess()
        retainRemoteProcess(operation, id: id)
        operation.start(cli: cli, arguments: ["remote"] + arguments, timeout: timeout,
                        onLine: onLine, completion: { [weak self] result in
            self?.releaseRemoteProcess(id)
            completion(result)
        })
        return operation
    }

    var activeRemoteProcessCount: Int { remoteProcesses.count }
    func retainRemoteProcess(_ process: RemoteCLIProcess, id: UUID) { remoteProcesses[id] = process }
    func releaseRemoteProcess(_ id: UUID) { remoteProcesses.removeValue(forKey: id) }

    /// A CLI anyone in the admin group can replace is not one to execute
    /// silently; /opt/homebrew/bin is group-writable on many machines.
    nonisolated private static func isGroupOrWorldWritable(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attrs[.posixPermissions] as? NSNumber
        else { return true }
        return permissions.uint16Value & 0o022 != 0
    }

    convenience init() { self.init(testingWithoutStartup: false) }

    init(testingWithoutStartup: Bool) {
        guard !testingWithoutStartup else { return }
        observeRunningApps()
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
            // reload() re-reads the instance list before both checks, so an
            // engine switch made from the CLI reaches the menu too.
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        primaryInstalled = FileManager.default.fileExists(atPath: Self.primaryAppPath)
        claudeInstalled = FileManager.default.fileExists(atPath: InstanceApp.claude.path)
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
            let claudeResult = Self.runProcess(cli: cli, arguments: ["--app", "claude", "list", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let message):
                    self.report(message, for: "list")
                case .success(let stdout):
                    guard case .success(let claudeOutput) = claudeResult else {
                        if case .failure(let message) = claudeResult { self.report(message, for: "list") }
                        return
                    }
                    self.clearReport(for: "list")
                    self.instances = (Self.parsePorcelain(stdout) + Self.parsePorcelain(claudeOutput, appKind: .claude))
                        .sorted { $0.name < $1.name }
                    self.listLoaded = true
                    self.checkPermissions()
                    self.checkNativeTools()
                    self.checkCreatorMicro()
                }
            }
        }
    }

    func launch(_ instance: Instance) {
        runCLI(instance.appKind.cliPrefix + ["launch", instance.name], busyKey: instance.id) { [weak self] failure in
            if failure == nil { self?.checkNativeTools() }
        }
    }

    /// Brings an open clone forward without a CLI round trip. Anything this
    /// cannot find running, including a profile on the official engine, goes
    /// through launch, which activates what is already open.
    func show(_ instance: Instance) {
        if !instance.usesBuiltInBrowser,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               Self.pathsMatch($0.bundleURL?.path ?? "", instance.appPath)
           }) {
            app.activate()
            return
        }
        launch(instance)
    }

    func assignBuiltInBrowser(to instance: Instance) {
        guard instance.appKind == .chatgpt else { return }
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
        alert.messageText = "Restart ChatGPT and assign Browser?"
        let reason = detail
            .replacingOccurrences(of: "doppel: ", with: "")
            .replacingOccurrences(
                of: "the Browser assignment needs running ChatGPT apps to quit: ",
                with: "")
        alert.informativeText = """
            Doppel will close the affected ChatGPT apps and reopen running managed instances after assigning the built-in Browser to \(instance.name). Other Doppel clones will stay open.

            \(reason)

            Save any unfinished drafts before continuing.
            """
        alert.addButton(withTitle: "Restart and Assign")
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
        runCLI(["browser", "release", "--quit-running"], busyKey: "iab-slot") { [weak self] _ in
            self?.reload()
        }
    }

    func assignCreatorMicro(to instance: Instance) {
        guard instance.appKind == .chatgpt else { return }
        runCLI(["micro", "assign", instance.name], busyKey: "creator-micro") { [weak self] _ in
            self?.checkCreatorMicro()
        }
    }

    func releaseCreatorMicro() {
        runCLI(["micro", "release"], busyKey: "creator-micro") { [weak self] _ in
            self?.checkCreatorMicro()
        }
    }

    func checkCreatorMicro() {
        guard !checkingCreatorMicro, !busy.contains("creator-micro"), let cli = discoveredCLI else { return }
        checkingCreatorMicro = true
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["micro", "status", "--porcelain"])
            let channels = Self.runProcess(cli: cli, arguments: ["micro", "channel", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingCreatorMicro = false
                if case .success(let output) = channels {
                    self.microChannels = MicroChannels.parse(output)
                }
                switch result {
                case .failure(let message):
                    self.creatorMicroStatusAvailable = false
                    self.creatorMicroOwnerID = nil
                    self.report(message, for: "creator-micro-status")
                case .success(let output):
                    self.clearReport(for: "creator-micro-status")
                    self.creatorMicroStatusAvailable = true
                    self.creatorMicroOwnerID = Self.parseCreatorMicroOwner(output)
                }
            }
        }
    }

    /// Gives an instance one Bluetooth channel of the pad, or with nil lets it
    /// listen on every channel again. Instances read it when they start.
    func setMicroChannel(_ channel: Int?, for instance: Instance) {
        guard instance.appKind == .chatgpt else { return }
        runCLI(["micro", "channel", instance.name, channel.map(String.init) ?? "any"],
               busyKey: "creator-micro") { [weak self] _ in
            self?.checkCreatorMicro()
        }
    }

    /// Asks the CLI what setting up Claude Code would change. The Codex Micro
    /// page shows the plan and applies it only when the user confirms there.
    func planClaudeMicro(channel: String) {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("creator-micro")
        Task.detached { [weak self] in
            let plan = Self.runProcess(cli: cli, arguments: ["micro", "claude", channel, "--plan"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove("creator-micro")
                switch plan {
                case .failure(let message):
                    self.report(message, for: "creator-micro")
                case .success(let output):
                    self.claudeMicroPlan = ClaudeMicroPlan(channel: channel, output: output)
                }
            }
        }
    }

    func applyClaudeMicroPlan() {
        guard let plan = claudeMicroPlan else { return }
        claudeMicroPlan = nil
        guard !plan.nothingToChange else { return }
        runCLI(["micro", "claude", plan.channel, "--yes"], busyKey: "creator-micro") { [weak self] failure in
            if failure == nil {
                Notifier.post("Claude Code is set up for the pad",
                              "New Claude Code sessions pick it up.")
            }
            self?.checkCreatorMicro()
        }
    }

    nonisolated private func globalProgressSink() -> @Sendable (CLIProgress) -> Void {
        { [weak self] step in Task { @MainActor in self?.progress = step } }
    }

    nonisolated private func instanceProgressSink(_ id: String) -> @Sendable (CLIProgress) -> Void {
        { [weak self] step in Task { @MainActor in self?.instanceProgress[id] = step } }
    }

    func rebuild(_ instance: Instance) {
        runCLI(instance.appKind.cliPrefix + ["rebuild", instance.name], busyKey: instance.id,
               onProgress: instanceProgressSink(instance.id)) { [weak self] failure in
            self?.instanceProgress[instance.id] = nil
            if failure == nil {
                Notifier.post("\(instance.name) rebuilt", "It kept its account and chats and has reopened.")
                self?.checkPermissions()
                self?.checkNativeTools()
            }
        }
    }

    func importClaudeSessions(_ instance: Instance) {
        guard instance.appKind == .claude else { return }
        let alert = NSAlert()
        alert.messageText = "Import existing Code history?"
        alert.informativeText = "Sign into the intended account and open Code first. Doppel will copy matching local sessions from the original Claude app, keep this instance’s current sessions, and reopen it. Finish any running work before continuing."
        alert.addButton(withTitle: "Import and Reopen")
        alert.addButton(withTitle: "Cancel")
        guard present(alert) == .alertFirstButtonReturn else { return }
        runCLI(instance.appKind.cliPrefix + ["import-sessions", instance.name], busyKey: instance.id,
               successTitle: "Code history import finished") { [weak self] failure in
            if failure == nil { self?.reload() }
        }
    }

    /// Mirrors the CLI's global engine-operation lock so the menu avoids
    /// offering operations that would only be refused as concurrent work.
    var engineOperationBusy: Bool {
        busy.contains("creator-micro") || busy.contains("iab-slot") || busy.contains("update") || busy.contains("signing") ||
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
        guard instance.appKind == .chatgpt else { return }
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
            let claudeResult = Self.runProcess(cli: cli, arguments: ["--app", "claude", "permissions", "check", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingPermissions = false
                switch result {
                case .failure(let message):
                    self.report(message, for: "permissions-check")
                case .success(let output):
                    guard case .success(let claudeOutput) = claudeResult else {
                        if case .failure(let message) = claudeResult { self.report(message, for: "permissions-check") }
                        return
                    }
                    self.clearReport(for: "permissions-check")
                    self.permissionStatuses = PermissionIssue.parseStatuses(output) +
                        PermissionIssue.parseStatuses(claudeOutput, appKind: .claude)
                }
            }
        }
    }

    func handlePermission(_ permission: PermissionIssue) {
        switch permission.action {
        case .requestNative where !requestedPermissionIDs.contains(permission.id):
            if permission.nativeRequestCanStayInconclusive {
                requestedPermissionIDs.insert(permission.id)
            }
            runCLI(
                permission.appKind.cliPrefix + ["permissions", "request", permission.instanceName, permission.permission],
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
                    self.lastCheckWasCurrent = false
                    if userInitiated { self.report(message, for: "update-check") }
                case .success(let output):
                    self.clearReport(for: "update-check")
                    // Recorded whether or not there is an update to offer, so
                    // the panel can show the installed build either way.
                    self.installedChatGPT = InstalledChatGPT.parse(output)
                    // Only the CLI saying "current" means current. A line this
                    // version cannot read, a state word added by a newer CLI
                    // than the app, proves nothing either way.
                    self.lastCheckWasCurrent = Self.resultFields(output).first == "current"
                    guard let update = ChatGPTUpdate.parse(output) else {
                        self.chatGPTUpdate = nil
                        if userInitiated && !self.lastCheckWasCurrent {
                            self.report(Self.unreadableUpdateCheckMessage, for: "update-check")
                        }
                        return
                    }
                    self.chatGPTUpdate = update
                    self.announce(update)
                }
            }
        }
    }

    /// The panel's banner is the offer. Acting on it starts the work at once:
    /// the banner already says what closes, and a second dialog repeating it
    /// was the modal the redesign set out to remove.
    func beginKnownUpdate() {
        guard let update = chatGPTUpdate else {
            checkForUpdates(userInitiated: true)
            return
        }
        switch update.state {
        case .available: prepareUpdate(update)
        case .ready, .staleInstances: applyUpdate(update)
        }
    }

    /// One notification per offer and build, so the six-hourly check does not
    /// repeat itself. Keyed by the state that produced it, so a reconcile offer
    /// for the installed build is not hidden by an earlier download offer that
    /// named the same number.
    private func announce(_ update: ChatGPTUpdate) {
        guard !announcedUpdates.contains(update.offerKey) else { return }
        announcedUpdates.insert(update.offerKey)
        let message = StatusMessages.offer(update)
        Notifier.post(message.title, message.body)
    }

    private func prepareUpdate(_ update: ChatGPTUpdate) {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("update")
        progressNote = StatusMessages.progress(for: update)
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["update", "prepare"],
                                         onProgress: self?.globalProgressSink())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove("update")
                self.progressNote = nil
                self.progress = nil
                switch result {
                case .failure(let message):
                    self.report(message, for: "update")
                case .success(let output):
                    self.clearReport(for: "update")
                    // `update prepare` also succeeds with "already current"
                    // when the vendor's own updater installed the build while
                    // Doppel was downloading it. Offering "Restart and Update"
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
                    self.announce(ready)
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

    private func applyUpdate(_ update: ChatGPTUpdate) {
        guard let cli = discoveredCLI else {
            report(Self.missingCLIMessage, for: "cli")
            return
        }
        busy.insert("update")
        progressNote = StatusMessages.progress(for: update)
        Task.detached { [weak self] in
            let result = Self.runProcess(
                cli: cli, arguments: ["update", "apply", String(update.targetBuild)],
                onProgress: self?.globalProgressSink())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove("update")
                self.progressNote = nil
                self.progress = nil
                switch result {
                case .failure(let message):
                    self.report(message, for: "update")
                    // The cached offer is what was just refused. Keeping it
                    // would let the same doomed apply be retried from the panel;
                    // re-reading is also how a primary that moved underneath
                    // Doppel turns into the reconcile offer that fixes it.
                    self.chatGPTUpdate = nil
                    self.checkForUpdates()
                case .success(let output):
                    self.clearReport(for: "update")
                    self.chatGPTUpdate = nil
                    self.reload()
                    let message = StatusMessages.completion(update, output: output,
                                                            signingReady: self.signingReady)
                    Notifier.post(message.title, message.body)
                }
            }
        }
    }

    /// Presents an alert so it is actually seen. Activation is cooperative on
    /// macOS 14+: a menu-bar app raising a modal from a timer or a finished
    /// background task can be denied, which leaves the alert behind the
    /// frontmost app or off the user's full-screen Space.
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

    /// Creates an instance from just a name and a tint color; the CLI derives
    /// bundle id, URL scheme, and data directories from the name.
    func create(name: String, tintHex: String, appKind: InstanceApp = .chatgpt, completion: @escaping (String?) -> Void) {
        let tintArguments = tintHex == "original" ? ["--original-icon"] : ["--tint", tintHex]
        // As with edit: the window is still on screen and shows the failure
        // itself.
        runCLI(appKind.cliPrefix + ["create", "--name", name] + tintArguments, busyKey: "create",
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
        runCLI(instance.appKind.cliPrefix + arguments, busyKey: instance.id, reportFailure: false) { [weak self] failure in
            if failure == nil { self?.reload() }
            completion(failure)
        }
    }

    /// Removal moves the app to the Trash and keeps account data unless the
    /// user explicitly opts into deleting it, so the dialog states both.
    func confirmRemove(_ instance: Instance) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(instance.name)”?"
        alert.informativeText = """
            The app moves to the Trash and can be rebuilt at any time.
            Its account data (chats and login) is kept unless you tick below.
            """
        if instance.appKind == .chatgpt {
            alert.informativeText += "\nRemote Access is disabled first, interrupting any remote tasks."
        }
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
        guard present(alert) == .alertFirstButtonReturn else { return }
        remove(instance, purgeData: purge.state == .on)
    }

    /// Removes an instance. The CLI moves the app to the Trash and keeps the
    /// instance definition; account data is only touched with purgeData.
    func remove(_ instance: Instance, purgeData: Bool) {
        var arguments = ["remove", instance.name]
        if purgeData { arguments.append("--purge-data") }
        runCLI(instance.appKind.cliPrefix + arguments, busyKey: instance.id) { [weak self] failure in
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
        progressNote = instances.isEmpty
            ? "Setting up secure signing…"
            : "Setting up secure signing and rebuilding every instance…"
        let rebuildCommands = instances.map { $0.appKind.cliPrefix + ["rebuild", $0.name] }
        Task.detached { [weak self] in
            let failure = SigningIdentity.setUp(cli: cli)
            if failure == nil {
                for (index, arguments) in rebuildCommands.enumerated() {
                    let step = CLIProgress(fraction: Double(index) / Double(rebuildCommands.count),
                                           label: "Rebuilding \(arguments.last ?? ""), \(index + 1) of \(rebuildCommands.count)")
                    await MainActor.run { [weak self] in self?.progress = step }
                    _ = Self.runProcess(cli: cli, arguments: arguments)
                }
            }
            await MainActor.run { [weak self] in
                self?.busy.remove("signing")
                self?.progressNote = nil
                self?.progress = nil
                if let failure {
                    self?.report(failure, for: "signing")
                } else {
                    Notifier.post("Secure signing is ready",
                                  "Instances keep their macOS permissions across updates.")
                }
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

    /// Failures are posted as a notification when they happen and stay in the
    /// panel until dismissed. A condition that persists across reloads is
    /// raised once rather than after every refresh.
    private func report(_ message: String, for key: String) {
        guard reported[key] != message else { return }
        reported[key] = message
        let summary = CLIErrorReport.summary(message)
        lastError = summary
        Notifier.post("Doppel could not finish that", summary)
    }

    private func clearReport(for key: String) {
        reported[key] = nil
    }

    nonisolated static func parsePorcelain(_ output: String, appKind: InstanceApp = .chatgpt) -> [Instance] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            // Tint and engine were added later; older output stays readable
            // and defaults to the historical locally signed engine.
            guard fields.count >= 4 else { return nil }
            return Instance(
                id: appKind.instanceID(String(fields[0])),
                name: String(fields[1]),
                appPath: String(fields[2]),
                installed: fields[3] == "installed",
                tint: fields.count > 4 ? String(fields[4]) : "",
                engine: fields.count > 5
                    ? InstanceEngine(rawValue: String(fields[5])) ?? .clone
                    : .clone,
                appKind: appKind
            )
        }
    }

    nonisolated static func parseCreatorMicroOwner(_ output: String) -> String? {
        let fields = output.trimmingCharacters(in: .newlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "owner", !fields[1].isEmpty else { return nil }
        return String(fields[1])
    }

    /// With onProgress, the CLI is asked for its progress lines and they are
    /// delivered as they arrive, on whatever thread reads the pipe.
    nonisolated private static func runProcess(cli: URL, arguments: [String],
                                               onProgress: (@Sendable (CLIProgress) -> Void)? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [cli.path] + arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stderrBuffer = ProgressStream(onProgress: onProgress)
        if onProgress != nil {
            var environment = ProcessInfo.processInfo.environment
            environment["DOPPEL_PROGRESS"] = "1"
            process.environment = environment
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }
        }
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            if process.terminationStatus != 0 {
                // Fall back through stderr, then stdout: a bare "exited 1" tells
                // the user nothing about what actually went wrong.
                let stderr = CLIProgress.withoutProgress(stderrBuffer.text)
                let detail = !stderr.isEmpty
                    ? stderr
                    : stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty ? "doppel exited \(process.terminationStatus)" : detail
                try? CLIErrorReport.record(message, arguments: arguments, to: CLIErrorReport.logURL)
                return .failure(CLIErrorReport.summary(message))
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
                        successTitle: String? = nil,
                        onProgress: (@Sendable (CLIProgress) -> Void)? = nil,
                        completion: (@MainActor (String?) -> Void)? = nil) {
        guard let cli = discoveredCLI else {
            if reportFailure { report(Self.missingCLIMessage, for: "cli") }
            completion?(Self.missingCLIMessage)
            return
        }
        busy.insert(busyKey)
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: arguments, onProgress: onProgress)
            let failure: String?
            if case .failure(let message) = result { failure = message } else { failure = nil }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(busyKey)
                if let failure {
                    if reportFailure { self.report(failure, for: busyKey) }
                } else {
                    self.clearReport(for: busyKey)
                    if let successTitle, case .success(let output) = result {
                        Notifier.post(successTitle, output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                completion?(failure)
            }
        }
    }
}

/// Collects a child's stderr while it runs, handing each complete progress
/// line on as it arrives and keeping everything for the failure message.
private final class ProgressStream: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let onProgress: (@Sendable (CLIProgress) -> Void)?

    init(onProgress: (@Sendable (CLIProgress) -> Void)?) { self.onProgress = onProgress }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        pending += String(decoding: chunk, as: UTF8.self)
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        lock.unlock()
        guard let onProgress else { return }
        for line in lines { if let step = CLIProgress.parse(line) { onProgress(step) } }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Swift's Result requires Failure: Error; a plain enum is simpler here.
enum ProcessResult {
    case success(String)
    case failure(String)
}
