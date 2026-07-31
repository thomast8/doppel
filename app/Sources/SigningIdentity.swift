import Foundation

/// The local signing identity, driven through `bin/doppel-signing` so the app
/// and the CLI cannot disagree about what "set up" means.
enum SigningIdentity {
    enum State: Equatable {
        case present(sha1: String)
        case absent
        case unknown(String)

        var isPresent: Bool { if case .present = self { return true }; return false }
    }

    static func status(cli: URL) -> State {
        switch run(cli: cli, arguments: ["status"]) {
        case .failure(let message):
            return .unknown(message)
        case .success(let output):
            guard output.contains("identity: present") else { return .absent }
            let sha = output
                .split(separator: "\n")
                .first { $0.hasPrefix("sha1:") }?
                .replacingOccurrences(of: "sha1:", with: "")
                .trimmingCharacters(in: .whitespaces) ?? ""
            return .present(sha1: sha)
        }
    }

    /// Returns nil on success, else a message worth showing the user.
    static func setUp(cli: URL) -> String? {
        if case .failure(let message) = run(cli: cli, arguments: ["setup"]) {
            return message
        }
        return nil
    }

    private static func run(cli: URL, arguments: [String]) -> ProcessResult {
        let signingCLI = cli.deletingLastPathComponent().appendingPathComponent("doppel-signing")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [signingCLI.path] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(stderr.isEmpty ? "doppel-signing exited \(process.terminationStatus)" : stderr)
            }
            return .success(stdout)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
