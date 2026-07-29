import Foundation

/// Start-at-login, implemented as a launchd user agent.
///
/// SMAppService would be the modern route, but it requires a Developer
/// ID-signed bundle; Doppel builds are ad-hoc signed locally, so a plain user
/// LaunchAgent is what actually works here. KeepAlive stays false so quitting
/// from the menu stays quit until the next login.
enum LoginItem {
    static let label = "ai.doppel.menubar"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Registers or removes the agent. Returns nil on success, else a message.
    static func setEnabled(_ enabled: Bool) -> String? {
        enabled ? enable() : disable()
    }

    private static func enable() -> String? {
        let executable = Bundle.main.executableURL?.path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Doppel").path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logDirectory = home.appendingPathComponent("Library/Logs/Doppel")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardErrorPath": logDirectory.appendingPathComponent("menubar.err").path,
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "Could not write the login item: \(error.localizedDescription)"
        }
        // Replace any previous registration so the path stays current.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        if let failure = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) {
            return "Could not register the login item: \(failure)"
        }
        return nil
    }

    private static func disable() -> String? {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            return "Could not remove the login item: \(error.localizedDescription)"
        }
        return nil
    }

    /// Returns nil on success, else launchctl's message.
    private static func runLaunchctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message?.isEmpty == false ? message! : "launchctl exited \(process.terminationStatus)"
        } catch {
            return error.localizedDescription
        }
    }
}
