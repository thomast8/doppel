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

    /// The last failure already reported for a given piece of work, so a
    /// condition that persists across reloads is raised once rather than after
    /// every refresh.
    private var reported: [String: String] = [:]

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
                }
            }
        }
    }

    func launch(_ instance: Instance) {
        runCLI(["launch", instance.name], busyKey: instance.id)
    }

    func rebuild(_ instance: Instance) {
        runCLI(["rebuild", instance.name], busyKey: instance.id)
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Doppel could not finish that"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
