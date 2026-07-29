import Foundation
import AppKit

struct Instance: Identifiable {
    let id: String        // stable slug assigned at creation
    let name: String
    let appPath: String
    let installed: Bool
}

/// All instance knowledge comes from the CLI (`doppel list --porcelain`), so
/// the menu-bar app and the CLI cannot drift apart on config parsing.
@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var busy: Set<String> = []
    @Published var lastError: String?
    @Published var primaryInstalled = false

    static let primaryAppPath = "/Applications/ChatGPT.app"
    static let primaryDownloadURL = URL(string: "https://chatgpt.com/features/desktop/")!

    /// The CLI location: DOPPEL_CLI overrides, then known install locations.
    private var discoveredCLI: URL? {
        if let override = ProcessInfo.processInfo.environment["DOPPEL_CLI"] {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("GitRepos/doppel/bin/doppel").path,
            "/opt/homebrew/bin/doppel",
            "/usr/local/bin/doppel",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    init() {
        reload()
    }

    func reload() {
        lastError = nil
        primaryInstalled = FileManager.default.fileExists(atPath: Self.primaryAppPath)
        guard let cli = discoveredCLI else {
            instances = []
            lastError = "doppel CLI not found; set the DOPPEL_CLI environment variable"
            return
        }
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: ["list", "--porcelain"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let message):
                    self.lastError = message
                case .success(let stdout):
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
        runCLI(["create", "--name", name, "--tint", tintHex], busyKey: "create") { [weak self] failure in
            if failure == nil { self?.reload() }
            completion(failure)
        }
    }

    nonisolated private static func parsePorcelain(_ output: String) -> [Instance] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            return Instance(
                id: String(fields[0]),
                name: String(fields[1]),
                appPath: String(fields[2]),
                installed: fields[3] == "installed"
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
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(stderr?.isEmpty == false ? stderr! : "doppel exited \(process.terminationStatus)")
            }
            return .success(stdout)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func runCLI(_ arguments: [String], busyKey: String,
                        completion: (@MainActor (String?) -> Void)? = nil) {
        guard let cli = discoveredCLI else {
            lastError = "doppel CLI not found; set the DOPPEL_CLI environment variable"
            completion?(lastError)
            return
        }
        busy.insert(busyKey)
        lastError = nil
        Task.detached { [weak self] in
            let result = Self.runProcess(cli: cli, arguments: arguments)
            let failure: String?
            if case .failure(let message) = result { failure = message } else { failure = nil }
            await MainActor.run { [weak self] in
                self?.busy.remove(busyKey)
                if let failure { self?.lastError = failure }
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
