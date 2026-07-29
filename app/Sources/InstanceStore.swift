import Foundation
import AppKit

struct Instance: Identifiable {
    let id: String        // directory slug
    let name: String
    let appPath: String
}

/// Reads instance definitions written by `doppel create` and shells out to the
/// CLI for actions, so the menu-bar app and the CLI can never disagree.
@MainActor
final class InstanceStore: ObservableObject {
    @Published var instances: [Instance] = []
    @Published var busy: Set<String> = []
    @Published var lastError: String?
    @Published var primaryInstalled = false

    static let primaryAppPath = "/Applications/ChatGPT.app"
    static let primaryDownloadURL = URL(string: "https://chatgpt.com/features/desktop/")!

    private let instancesRoot = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Doppel/instances")

    /// The CLI location; override with the DOPPEL_CLI environment variable.
    private var cliURL: URL {
        if let override = ProcessInfo.processInfo.environment["DOPPEL_CLI"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("GitRepos/doppel/bin/doppel")
    }

    init() {
        reload()
    }

    func reload() {
        lastError = nil
        primaryInstalled = FileManager.default.fileExists(atPath: Self.primaryAppPath)
        var found: [Instance] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: instancesRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            let config = dir.appendingPathComponent("instance-config.zsh")
            guard let text = try? String(contentsOf: config, encoding: .utf8),
                  let name = firstQuotedValue(for: "DOPPEL_DISPLAY_NAME", in: text)
            else { continue }
            let installRootFile = dir.appendingPathComponent("install-root")
            let installRoot = (try? String(contentsOf: installRootFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications").path
            found.append(Instance(
                id: dir.lastPathComponent,
                name: name,
                appPath: "\(installRoot)/\(name).app"
            ))
        }
        instances = found.sorted { $0.name < $1.name }
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

    private func firstQuotedValue(for key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
            return line.split(separator: "\"").dropFirst().first.map(String.init)
        }
        return nil
    }

    private func runCLI(_ arguments: [String], busyKey: String,
                        completion: (@MainActor (String?) -> Void)? = nil) {
        busy.insert(busyKey)
        lastError = nil
        let cli = cliURL
        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [cli.path] + arguments
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()
            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    failure = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
                }
            } catch {
                failure = error.localizedDescription
            }
            let outcome = failure
            await MainActor.run { [weak self] in
                self?.busy.remove(busyKey)
                if let outcome { self?.lastError = outcome }
                completion?(outcome)
            }
        }
    }
}
