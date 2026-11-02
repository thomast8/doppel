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
    let name: String
    var bridgeID: UUID?
    var bridges: [ChromeBridge]?
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
                guard Set(profiles.map(\.id)).count == profiles.count else {
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

    func addBridge(_ bridge: ChromeBridge, to profile: ChromeProfile) throws -> ChromeProfile {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { throw failure("Unknown Chrome profile.") }
        var updated = profiles[index]
        if !updated.enabledBridges.contains(bridge) { updated.bridges = updated.enabledBridges + [bridge] }
        try prepare(updated)
        var values = profiles
        values[index] = updated
        try save(values)
        return updated
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
                  let executable = host["path"] as? String,
                  executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
                  let origins = host["allowed_origins"] as? [String],
                  origins.contains("chrome-extension://\(bridge.extensionID)/") else {
                throw failure("The \(bridge.label) browser bridge is unavailable. \(help)")
            }
            manifests.append((bridge, data))
        }
        let destination = directory(profile)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let defaultProfile = destination.appendingPathComponent("Default")
        if !FileManager.default.fileExists(atPath: defaultProfile.path) {
            try FileManager.default.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
            let preferences: [String: Any] = ["profile": ["name": profile.name]]
            try JSONSerialization.data(withJSONObject: preferences).write(
                to: defaultProfile.appendingPathComponent("Preferences"), options: .atomic)
        }
        let registrations = destination.appendingPathComponent("NativeMessagingHosts")
        try FileManager.default.createDirectory(at: registrations, withIntermediateDirectories: true)
        for (bridge, data) in manifests {
            try data.write(to: registrations.appendingPathComponent(bridge.hostName + ".json"), options: .atomic)
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

    func launch(_ profile: ChromeProfile, setup: Bool = false, completion: ((Error?) -> Void)? = nil) {
        do {
            guard FileManager.default.fileExists(atPath: Self.chrome.path) else { throw failure("Install Google Chrome in Applications first.") }
            try prepare(profile)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = launchArguments(profile, setup: setup)
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
            return "Use Claude in Chrome only in my Doppel profile. In Claude Code, use /chrome > Select browser to choose it. Before any browser action, confirm the selected browser contains this exact connection tab: \(marker(profile).absoluteString). If the tab is absent or selection cannot be confirmed, stop and ask me to select the correct profile. Never use main Chrome as a fallback. Recheck after reconnecting."
        }
        if let id = profile.bridgeID {
            return "Use only the Chrome bridge with extensionInstanceId \(id.uuidString.lowercased()). Select it explicitly with cua.getBrowser({extensionInstanceId: '\(id.uuidString.lowercased())'}). If unavailable, stop and ask me to open this Doppel profile. Never fall back to generic Chrome or another browser."
        }
        return "Pair my Doppel Chrome profile. List connected extension browsers and their tabs. Find exactly one whose tabs contain this exact URL: \(marker(profile).absoluteString). Return that browser's metadata.extensionInstanceId for me to paste into Doppel's Pair ChatGPT Bridge dialog. If none or multiple match, stop. Do not select by generic Chrome, display name, or URL-based getBrowser, and do not control another browser."
    }

    func copyInstructions(_ profile: ChromeProfile, bridge: ChromeBridge = .chatgpt) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(instructions(profile, bridge: bridge), forType: .string)
    }

    func addClaudeBridge(_ profile: ChromeProfile) {
        perform { launch(try addBridge(.claude, to: profile), setup: true) }
    }

    func promptCreate() {
        PanelWindow.close()
        let alert = NSAlert()
        alert.messageText = "New Chrome Profile"
        alert.informativeText = "Name the profile and choose its browser bridges. Chrome asks you to confirm each extension installation."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Work"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        picker.addItems(withTitles: ["ChatGPT", "Claude Code", "ChatGPT and Claude Code"])
        let accessory = NSStackView(views: [field, picker])
        accessory.orientation = .vertical
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let bridges: [ChromeBridge] = picker.indexOfSelectedItem == 2 ? ChromeBridge.allCases
            : [picker.indexOfSelectedItem == 1 ? .claude : .chatgpt]
        perform { launch(try create(name: field.stringValue, bridges: bridges), setup: true) }
    }

    func promptPair(_ profile: ChromeProfile) {
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
    @StateObject private var store = ChromeProfiles()
    var body: some View {
        Menu("Chrome Profiles") {
            if let error = store.loadError { Text(error) }
            ForEach(store.profiles) { profile in
                Menu(profile.name) {
                    Text(profile.enabledBridges.map(\.label).joined(separator: " + "))
                    Button("Open") { store.launch(profile) }
                    Button("Set Up Bridge…") { store.launch(profile, setup: true) }
                    if profile.enabledBridges.contains(.chatgpt) {
                        Text(profile.bridgeID == nil ? "ChatGPT bridge needs pairing" : "ChatGPT bridge paired")
                        Button("Copy ChatGPT Instructions") { store.copyInstructions(profile) }
                        Button("Pair ChatGPT Bridge…") { store.promptPair(profile) }
                    }
                    if profile.enabledBridges.contains(.claude) {
                        Button("Copy Claude Code Instructions") { store.copyInstructions(profile, bridge: .claude) }
                    } else {
                        Button("Add Claude Code Bridge…") { store.addClaudeBridge(profile) }
                    }
                }
            }
            Divider()
            Button("New Chrome Profile…") { store.promptCreate() }
                .disabled(store.loadError != nil)
        }
    }
}
