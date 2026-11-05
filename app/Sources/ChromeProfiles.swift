import AppKit
import SwiftUI

enum ChromeBridge: String, Codable, CaseIterable {
    case chatgpt, claude
    var label: String { self == .chatgpt ? "ChatGPT" : "Claude Code" }
    var hostName: String { self == .chatgpt ? "com.openai.codexextension" : "com.anthropic.claude_code_browser_extension" }
    var extensionID: String { self == .chatgpt ? "hehggadaopoacecdllhhajmbjkdcmajg" : "fcoeoabgfenejglbffodgkkbkcdhcgfn" }
    var storeURL: String { "https://chromewebstore.google.com/detail/\(self == .chatgpt ? "chatgpt" : "claude")/\(extensionID)" }
}

struct ChromeProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bridgeID: UUID?
    var bridges: [ChromeBridge]?
    var ownerID: String?
    var ownerAgentHome: String?
    var accountConfirmed: Bool?
    var enabledBridges: [ChromeBridge] { bridges ?? [.chatgpt] }
}

/// Browser profiles never enter the clone/update/permission machinery.
@MainActor
final class ChromeProfiles: ObservableObject {
    @Published private(set) var profiles: [ChromeProfile] = []
    @Published private(set) var loadError: String?
    let root: URL
    let hostManifest: URL
    let claudeHostManifest: URL
    static let extensionID = ChromeBridge.chatgpt.extensionID
    static let storeURL = ChromeBridge.chatgpt.storeURL
    static let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")

    init(root: URL? = nil, hostManifest: URL? = nil, claudeHostManifest: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? home.appendingPathComponent("Library/Application Support/Doppel/chrome")
        self.hostManifest = hostManifest ?? home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.openai.codexextension.json")
        self.claudeHostManifest = claudeHostManifest ?? home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json")
        do {
            let file = self.root.appendingPathComponent("profiles.json")
            if FileManager.default.fileExists(atPath: file.path) {
                profiles = try JSONDecoder().decode([ChromeProfile].self, from: Data(contentsOf: file))
                let owners = profiles.compactMap(\.ownerID)
                guard Set(profiles.map(\.id)).count == profiles.count,
                      Set(owners).count == owners.count else {
                    throw failure("Duplicate Chrome profiles in saved settings.")
                }
            }
        } catch { loadError = error.localizedDescription }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Doppel.Chrome", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func directory(_ profile: ChromeProfile) -> URL {
        root.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    func marker(_ profile: ChromeProfile) -> URL {
        directory(profile).appendingPathComponent("connection.html")
    }

    private func save(_ values: [ChromeProfile]) throws {
        guard loadError == nil else { throw failure("Saved Chrome profiles could not be read. Resolve that error before making changes.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("profiles.json"), options: .atomic)
        profiles = values
    }

    @discardableResult
    func create(name: String, bridges: [ChromeBridge] = [.chatgpt]) throws -> ChromeProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw failure("Use a profile name of 1–80 characters without control characters.")
        }
        guard !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw failure("A Chrome profile with that name already exists.")
        }
        let profile = ChromeProfile(id: UUID(), name: name, bridges: bridges)
        try save(profiles + [profile])
        return profile
    }

    func profile(for instance: Instance) -> ChromeProfile? {
        profiles.first { $0.ownerID == instance.id }
    }

    @discardableResult
    func ensureProfile(for instance: Instance) throws -> ChromeProfile {
        guard let home = instance.agentHome, home.hasPrefix("/") else {
            throw failure("The instance's account directory is unavailable. Update or reopen Doppel before setting up its browser.")
        }
        let bridge: ChromeBridge = instance.appKind == .chatgpt ? .chatgpt : .claude
        if let index = profiles.firstIndex(where: { $0.ownerID == instance.id }) {
            var values = profiles
            var updated = values[index]
            if updated.ownerAgentHome != home || updated.enabledBridges != [bridge] {
                guard try !isRunning(updated) else { throw failure("Quit this browser normally before changing its account directory.") }
                updated.accountConfirmed = false
            }
            updated.name = instance.name
            updated.ownerAgentHome = home
            updated.bridges = [bridge]
            if updated != values[index] {
                values[index] = updated
                try save(values)
            }
            return updated
        }
        let value = ChromeProfile(id: UUID(), name: instance.name, bridges: [bridge],
                                  ownerID: instance.id, ownerAgentHome: home, accountConfirmed: false)
        try save(profiles + [value])
        return value
    }

    func link(_ profile: ChromeProfile, to instance: Instance) throws {
        guard let home = instance.agentHome, home.hasPrefix("/"),
              let index = profiles.firstIndex(where: { $0.id == profile.id }),
              profiles[index].ownerID == nil, self.profile(for: instance) == nil else {
            throw failure("Only an unlinked browser can be linked to an instance without a browser. No data was moved.")
        }
        guard try !isRunning(profiles[index]) else {
            throw failure("Quit this browser normally before linking it to a managed account. Its data will be retained.")
        }
        var values = profiles
        values[index].ownerID = instance.id
        values[index].ownerAgentHome = home
        values[index].name = instance.name
        values[index].bridges = [instance.appKind == .chatgpt ? .chatgpt : .claude]
        values[index].accountConfirmed = false
        try save(values)
    }

    func confirmAccount(_ profile: ChromeProfile, confirmed: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }), profiles[index].ownerID != nil else {
            throw failure("Link this browser to a managed instance first.")
        }
        var values = profiles
        values[index].accountConfirmed = confirmed
        try save(values)
    }

    private func isRunning(_ profile: ChromeProfile) throws -> Bool {
        let pids = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" }
            .map { String($0.processIdentifier) }
        guard !pids.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pids.joined(separator: ","), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Could not check whether this browser is open. Quit Chrome's test profile and retry.") }
        return String(decoding: data, as: UTF8.self).contains("--user-data-dir=" + directory(profile).path)
    }

    static func codeCommand(agentHome: String) -> String? {
        guard agentHome.hasPrefix("/") else { return nil }
        let quoted = "'" + agentHome.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "CLAUDE_CONFIG_DIR=\(quoted) claude --chrome"
    }

    func pair(_ profile: ChromeProfile, id: String) throws {
        guard profile.enabledBridges.contains(.chatgpt) else { throw failure("This profile uses Claude Code. Select it through /chrome instead.") }
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw failure("Paste the extensionInstanceId returned by the browser tool.")
        }
        guard !profiles.contains(where: { $0.id != profile.id && $0.bridgeID == uuid }) else {
            throw failure("That bridge is already paired with another Doppel Chrome profile.")
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw failure("Chrome profile no longer exists.") }
        var values = profiles
        values[index].bridgeID = uuid
        try save(values)
    }

    /// Refresh the registration only inside this profile, never in main Chrome.
    func prepare(_ profile: ChromeProfile) throws {
        guard profiles.contains(where: { $0.id == profile.id }) else { throw failure("Unknown Chrome profile.") }
        var manifests: [(ChromeBridge, Data)] = []
        for bridge in profile.enabledBridges {
            let source = bridge == .chatgpt ? hostManifest : claudeHostManifest
            let help = bridge == .chatgpt
                ? "Install or repair the Browser plugin in ChatGPT."
                : "Enable Chrome in Claude Code with /chrome to install its native host."
            guard let data = try? Data(contentsOf: source),
                  let host = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  host["name"] as? String == bridge.hostName,
                  host["type"] as? String == "stdio",
                  let templatePath = host["path"] as? String,
                  let origins = host["allowed_origins"] as? [String],
                  origins.contains("chrome-extension://\(bridge.extensionID)/") else {
                throw failure("The \(bridge.label) browser bridge is unavailable. \(help)")
            }
            var registration = host
            var executable = templatePath
            if profile.ownerID != nil {
                guard let home = profile.ownerAgentHome, home.hasPrefix("/") else {
                    throw failure("This browser has no managed account directory. Open it from its instance page.")
                }
                if bridge == .claude {
                    executable = URL(fileURLWithPath: home).appendingPathComponent("chrome/chrome-native-host").path
                } else {
                    let hosts = URL(fileURLWithPath: home).appendingPathComponent(
                        "plugins/cache/openai-bundled/chrome/latest/extension-host/macos")
                    let candidates = (try? FileManager.default.contentsOfDirectory(at: hosts, includingPropertiesForKeys: nil)) ?? []
                    executable = candidates.map { $0.appendingPathComponent("ChatGPT for Chrome").path }
                        .sorted().first(where: FileManager.default.isExecutableFile(atPath:)) ?? ""
                }
            }
            guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
                throw failure("The \(bridge.label) host for \(profile.name) is unavailable. Set up the browser bridge in that managed account first.")
            }
            registration["path"] = executable
            manifests.append((bridge, profile.ownerID == nil ? data : try JSONSerialization.data(withJSONObject: registration)))
        }
        try prepareFiles(profile)
        let destination = directory(profile)
        let registrations = destination.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createDirectory(at: registrations, withIntermediateDirectories: true)
        for (bridge, data) in manifests {
            try data.write(to: registrations.appendingPathComponent(bridge.hostName + ".json"), options: .atomic)
        }
    }

    private func prepareFiles(_ profile: ChromeProfile) throws {
        guard profiles.contains(where: { $0.id == profile.id }) else { throw failure("Unknown Chrome profile.") }
        let destination = directory(profile)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if profile.ownerID != nil {
            // Keep old registrations outside Chrome's lookup path when adopting a profile.
            for bridge in ChromeBridge.allCases where !profile.enabledBridges.contains(bridge) {
                let old = destination.appendingPathComponent("NativeMessagingHosts/" + bridge.hostName + ".json")
                if FileManager.default.fileExists(atPath: old.path) {
                    let archive = destination.appendingPathComponent("previous-bridge-registrations")
                    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: old, to: archive.appendingPathComponent(UUID().uuidString + ".json"))
                }
            }
        }
        let defaultProfile = destination.appendingPathComponent("Default")
        if !FileManager.default.fileExists(atPath: defaultProfile.path) {
            try FileManager.default.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
            let preferences: [String: Any] = ["profile": ["name": profile.name]]
            try JSONSerialization.data(withJSONObject: preferences).write(
                to: defaultProfile.appendingPathComponent("Preferences"), options: .atomic)
        }
        let safeName = profile.name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let installLinks = profile.enabledBridges.map {
            "<p><a href=\"\($0.storeURL)\">Install the official \($0.label) extension</a></p>"
        }.joined()
        let html = """
        <!doctype html><meta charset="utf-8"><title>Doppel Chrome: \(safeName)</title>
        <h1>\(safeName)</h1><p>This is your separate Doppel Chrome profile.</p>
        <p>Keep this connection tab open while pairing the browser bridge.</p>
        <p>In Doppel, copy this profile’s ChatGPT or Claude Code instructions to connect your agent.</p>
        \(installLinks)
        """
        try Data(html.utf8).write(to: marker(profile), options: .atomic)
    }

    func launchArguments(_ profile: ChromeProfile, setup: Bool = false) -> [String] {
        var args = ["--user-data-dir=\(directory(profile).path)", "--no-first-run", "--no-default-browser-check", marker(profile).absoluteString]
        if setup { args.append(contentsOf: profile.enabledBridges.map(\.storeURL)) }
        return args
    }

    func launchEnvironment(_ profile: ChromeProfile) -> [String: String] {
        guard profile.ownerID != nil, let home = profile.ownerAgentHome, home.hasPrefix("/") else { return [:] }
        return [profile.enabledBridges == [.claude] ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME": home]
    }

    func launch(_ profile: ChromeProfile, setup: Bool = false, signInOnly: Bool = false, completion: ((Error?) -> Void)? = nil) {
        do {
            guard FileManager.default.fileExists(atPath: Self.chrome.path) else { throw failure("Install Google Chrome in Applications first.") }
            if signInOnly { try prepareFiles(profile) } else { try prepare(profile) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = launchArguments(profile, setup: setup)
            configuration.environment = launchEnvironment(profile)
            NSWorkspace.shared.openApplication(at: Self.chrome, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let completion { completion(error) }
                    else if let error { self.showError(error) }
                }
            }
        } catch {
            if let completion { completion(error) } else { showError(error) }
        }
    }

    func instructions(_ profile: ChromeProfile, bridge: ChromeBridge = .chatgpt) -> String {
        if bridge == .claude {
            let scopedCommand = profile.ownerAgentHome.flatMap(Self.codeCommand(agentHome:))
            if profile.ownerID != nil && scopedCommand == nil { return "Stop: this managed instance's Code configuration directory is unavailable." }
            let command = scopedCommand ?? "claude --chrome"
            return "Use the Chrome profile belonging to Doppel instance \(profile.name). Start Claude Code with this instance's configuration: \(command). Confirm that Code and the browser extension are signed into the matching account. Use /chrome > Select browser. Browser N labels alone do not prove identity. Claude's browser tools see only their session tab group: do not assume the separately opened connection tab is visible. If no group exists, stop and ask me to confirm the selected isolated browser before creating one. Never use main Chrome as a fallback. Reconfirm selection after reconnecting. Connection tab for manual identification: \(marker(profile).absoluteString)."

        }
        if let id = profile.bridgeID {
            return "Use only the Chrome bridge with extensionInstanceId \(id.uuidString.lowercased()). Select it explicitly with cua.getBrowser({extensionInstanceId: '\(id.uuidString.lowercased())'}). If unavailable, stop and ask me to open this Doppel profile. Never fall back to generic Chrome or another browser."
        }
        return "Pair my Doppel Chrome profile. List connected extension browsers and their tabs. Find exactly one whose tabs contain this exact URL: \(marker(profile).absoluteString). Return that browser's metadata.extensionInstanceId for me to paste into Doppel's Pair ChatGPT Bridge dialog. If none or multiple match, stop. Do not select by generic Chrome, display name, or URL-based getBrowser, and do not control another browser."
    }

    func copyInstructions(_ profile: ChromeProfile, bridge: ChromeBridge = .chatgpt) {
        guard profile.ownerID != nil, profile.accountConfirmed == true else {
            showError(failure("Confirm that the browser and its managed instance use the same account before connecting an agent."))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(instructions(profile, bridge: bridge), forType: .string)
    }

    func promptPair(_ profile: ChromeProfile) {
        guard profile.ownerID != nil, profile.accountConfirmed == true else { return }
        PanelWindow.close()
        let alert = NSAlert()
        alert.messageText = "Pair ChatGPT Bridge: \(profile.name)"
        alert.informativeText = "First use Copy ChatGPT Instructions with your agent. Paste the extensionInstanceId it returns. Confirm it belongs to this profile, not your main Chrome."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = profile.bridgeID?.uuidString.lowercased() ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try pair(profile, id: field.stringValue) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

struct ChromeProfilesMenu: View {
    @ObservedObject var store: ChromeProfiles
    var body: some View {
        let unlinked = store.profiles.filter { $0.ownerID == nil }
        if !unlinked.isEmpty {
            Menu("Unlinked Chrome Profiles") {
                Text("Link these from a managed instance's Browser section.")
                ForEach(unlinked) { profile in
                    Menu(profile.name) {
                        Button("Open") { store.launch(profile) }
                        Text("Browser data is retained.")
                    }
                }
            }
        }
    }
}
