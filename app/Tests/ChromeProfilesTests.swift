import XCTest
@testable import DoppelMenuBar

@MainActor
final class ChromeProfilesTests: XCTestCase {
    private func fixture() throws -> (ChromeProfiles, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("source-host.json")
        let host: [String: Any] = ["name": "com.openai.codexextension", "type": "stdio", "path": "/usr/bin/true",
                                   "allowed_origins": ["chrome-extension://\(ChromeProfiles.extensionID)/"]]
        try JSONSerialization.data(withJSONObject: host).write(to: manifest)
        return (ChromeProfiles(root: root.appendingPathComponent("managed"), hostManifest: manifest), root)
    }

    func testIndependentRootsAndPersistentPairing() throws {
        let (store, root) = try fixture()
        let a = try store.create(name: "A")
        let b = try store.create(name: "B")
        XCTAssertNotEqual(store.directory(a), store.directory(b))
        let id = UUID()
        try store.pair(a, id: id.uuidString)
        XCTAssertThrowsError(try store.pair(b, id: id.uuidString))
        XCTAssertThrowsError(try store.pair(b, id: "chrome"))
        let restored = ChromeProfiles(root: store.root, hostManifest: store.hostManifest)
        XCTAssertEqual(restored.profiles.first?.bridgeID, id)
        XCTAssertTrue(restored.instructions(restored.profiles[0]).contains(id.uuidString.lowercased()))
        XCTAssertTrue(restored.instructions(restored.profiles[0]).contains("Never fall back"))
        XCTAssertTrue(restored.directory(a).path.hasPrefix(root.path))
    }

    func testSetupOnlyWritesInsideManagedRootAndRefreshesHost() throws {
        let (store, _) = try fixture()
        let a = try store.create(name: "<Work & Test>")
        let source = try Data(contentsOf: store.hostManifest)
        try store.prepare(a)
        XCTAssertEqual(try Data(contentsOf: store.hostManifest), source)
        let destination = store.directory(a).appendingPathComponent("NativeMessagingHosts/com.openai.codexextension.json")
        XCTAssertEqual(try Data(contentsOf: destination), source)
        let html = try String(contentsOf: store.marker(a), encoding: .utf8)
        XCTAssertTrue(html.contains("&lt;Work &amp; Test&gt;"))
        XCTAssertTrue(store.launchArguments(a).contains("--user-data-dir=\(store.directory(a).path)"))
        XCTAssertTrue(store.launchArguments(a).contains("--no-default-browser-check"))
        XCTAssertFalse(store.launchArguments(a).contains(ChromeProfiles.storeURL))
        XCTAssertTrue(store.launchArguments(a, setup: true).contains(ChromeProfiles.storeURL))
        var host = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        host["path"] = "/usr/bin/false"
        try JSONSerialization.data(withJSONObject: host).write(to: store.hostManifest)
        try store.prepare(a)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: store.hostManifest))
        host["path"] = "/does/not/exist"
        try JSONSerialization.data(withJSONObject: host).write(to: store.hostManifest)
        XCTAssertThrowsError(try store.prepare(a))
    }

    func testClaudeOnlySetupDoesNotRequireChatGPT() throws {
        let (store, root) = try fixture()
        let claudeManifest = root.appendingPathComponent("claude-host.json")
        let host: [String: Any] = ["name": ChromeBridge.claude.hostName, "type": "stdio", "path": "/usr/bin/true",
                                   "allowed_origins": ["chrome-extension://\(ChromeBridge.claude.extensionID)/"]]
        try JSONSerialization.data(withJSONObject: host).write(to: claudeManifest)
        let both = ChromeProfiles(root: store.root, hostManifest: store.hostManifest, claudeHostManifest: claudeManifest)
        let onlyClaude = try both.create(name: "Claude", bridges: [.claude])
        let absentChatGPT = ChromeProfiles(root: store.root, hostManifest: root.appendingPathComponent("absent"), claudeHostManifest: claudeManifest)
        try absentChatGPT.prepare(onlyClaude)
        XCTAssertThrowsError(try absentChatGPT.pair(onlyClaude, id: UUID().uuidString))
        XCTAssertEqual(absentChatGPT.launchArguments(onlyClaude, setup: true).last, ChromeBridge.claude.storeURL)
        let instructions = absentChatGPT.instructions(onlyClaude, bridge: .claude)
        XCTAssertTrue(instructions.contains("/chrome > Select browser"))
        XCTAssertTrue(instructions.contains(absentChatGPT.marker(onlyClaude).absoluteString))
        XCTAssertFalse(instructions.contains("cua.getBrowser"))
        XCTAssertFalse(instructions.contains("Cowork"))
    }

    func testLegacyProfilesStillDefaultToChatGPT() throws {
        let id = UUID()
        let data = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"Legacy\"}]".utf8)
        let profiles = try JSONDecoder().decode([ChromeProfile].self, from: data)
        XCTAssertEqual(profiles[0].enabledBridges, [.chatgpt])
    }

    private func instance(_ id: String, name: String = "One", kind: InstanceApp = .chatgpt, home: String = "/tmp/account") -> Instance {
        Instance(id: id, name: name, appPath: "/Applications/One.app", installed: true,
                 tint: "", engine: .clone, appKind: kind, agentHome: home)
    }

    func testManagedOwnershipSurvivesRenameAndKeepsAppNamespacesSeparate() throws {
        let (store, _) = try fixture()
        let chatgpt = instance("one")
        let claude = instance("claude/one", kind: .claude)
        let a = try store.ensureProfile(for: chatgpt)
        let b = try store.ensureProfile(for: claude)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.enabledBridges, [.chatgpt])
        XCTAssertEqual(b.enabledBridges, [.claude])
        XCTAssertEqual(a.ownerID, "one")
        XCTAssertEqual(b.ownerID, "claude/one")
        XCTAssertEqual(store.launchEnvironment(a), ["CODEX_HOME": "/tmp/account"])
        XCTAssertEqual(store.launchEnvironment(b), ["CLAUDE_CONFIG_DIR": "/tmp/account"])
        XCTAssertEqual(a.accountConfirmed, false)
        let bridgeID = UUID()
        try store.pair(a, id: bridgeID.uuidString)
        try store.confirmAccount(a, confirmed: true)
        let renamed = try store.ensureProfile(for: instance("one", name: "Renamed"))
        XCTAssertEqual(renamed.id, a.id)
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.bridgeID, bridgeID)
        XCTAssertEqual(renamed.accountConfirmed, true)
        XCTAssertEqual(store.directory(renamed), store.directory(a))
        let changedHome = try store.ensureProfile(for: instance("one", home: "/tmp/new-account"))
        XCTAssertEqual(changedHome.id, a.id)
        XCTAssertEqual(changedHome.accountConfirmed, false)
        let restored = ChromeProfiles(root: store.root, hostManifest: store.hostManifest)
        XCTAssertEqual(restored.profile(for: claude)?.id, b.id)
        XCTAssertThrowsError(try store.ensureProfile(for: instance("missing", home: "")))
    }

    func testExplicitLinkRetainsDataAndRefusesReassignment() throws {
        let (store, _) = try fixture()
        let old = try store.create(name: "Old Standalone")
        try FileManager.default.createDirectory(at: store.directory(old), withIntermediateDirectories: true)
        let sentinel = store.directory(old).appendingPathComponent("retained-data")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try store.confirmAccount(old, confirmed: true))
        let owner = instance("owner")
        try store.link(old, to: owner)
        let linked = try XCTUnwrap(store.profile(for: owner))
        XCTAssertEqual(linked.id, old.id)
        XCTAssertEqual(linked.accountConfirmed, false)
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertThrowsError(try store.link(linked, to: instance("other")))
        let spare = try store.create(name: "Spare")
        XCTAssertThrowsError(try store.link(spare, to: owner))
        XCTAssertNil(store.profiles.first(where: { $0.id == spare.id })?.ownerID)
    }

    func testOwnedHostUsesOnlyTheOwnersRuntime() throws {
        let (store, root) = try fixture()
        let claudeTemplate = root.appendingPathComponent("claude-template.json")
        let template: [String: Any] = ["name": ChromeBridge.claude.hostName, "type": "stdio", "path": "/usr/bin/true",
                                       "allowed_origins": ["chrome-extension://\(ChromeBridge.claude.extensionID)/"]]
        let source = try JSONSerialization.data(withJSONObject: template)
        try source.write(to: claudeTemplate)
        let owned = ChromeProfiles(root: store.root, hostManifest: store.hostManifest, claudeHostManifest: claudeTemplate)
        let home = root.appendingPathComponent("managed-account")
        let profile = try owned.ensureProfile(for: instance("claude/owner", kind: .claude, home: home.path))
        XCTAssertThrowsError(try owned.prepare(profile), "A working global host must not substitute for a missing owner host")
        let binary = home.appendingPathComponent("chrome/chrome-native-host")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let inactive = owned.directory(profile).appendingPathComponent("NativeMessagingHosts/com.openai.codexextension.json")
        try FileManager.default.createDirectory(at: inactive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retained inactive registration".utf8).write(to: inactive)
        try owned.prepare(profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactive.path))
        let archived = try FileManager.default.contentsOfDirectory(at: owned.directory(profile).appendingPathComponent(
            "previous-bridge-registrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try String(contentsOf: archived[0]), "retained inactive registration")
        let registration = owned.directory(profile).appendingPathComponent("NativeMessagingHosts/" + ChromeBridge.claude.hostName + ".json")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registration)) as? [String: Any])
        XCTAssertEqual(saved["path"] as? String, binary.path)
        XCTAssertEqual(try Data(contentsOf: claudeTemplate), source)
        let instructions = owned.instructions(profile, bridge: .claude)
        XCTAssertTrue(instructions.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertTrue(instructions.contains("session tab group"))
        XCTAssertTrue(instructions.contains("stop and ask me"))
        let chatgpt = try owned.ensureProfile(for: instance("chatgpt-owner", home: home.path))
        XCTAssertThrowsError(try owned.prepare(chatgpt))
        let chatgptHost = home.appendingPathComponent("plugins/cache/openai-bundled/chrome/latest/extension-host/macos/test-arch/ChatGPT for Chrome")
        try FileManager.default.createDirectory(at: chatgptHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: chatgptHost)
        try owned.prepare(chatgpt)
        let chatgptRegistration = owned.directory(chatgpt).appendingPathComponent("NativeMessagingHosts/com.openai.codexextension.json")
        let chatgptSaved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: chatgptRegistration)) as? [String: Any])
        let savedHost = try XCTUnwrap(chatgptSaved["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: savedHost).resolvingSymlinksInPath(), chatgptHost.resolvingSymlinksInPath())
    }

    func testCodeCommandQuotesAccountDirectoryAsLiteralShellData() throws {
        let home = "/tmp/Account 'one' $(printf injected)"
        let command = try XCTUnwrap(ChromeProfiles.codeCommand(agentHome: home))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "claude() { /usr/bin/printenv CLAUDE_CONFIG_DIR; }\n" + command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let value = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: value, encoding: .utf8), home + "\n")
        XCTAssertNil(ChromeProfiles.codeCommand(agentHome: "relative/path"))
    }

    func testInvalidNamesAndCorruptStateAreNotOverwritten() throws {
        let (store, _) = try fixture()
        XCTAssertThrowsError(try store.create(name: "\n"))
        XCTAssertThrowsError(try store.create(name: "A\nB"))
        _ = try store.create(name: "Work")
        XCTAssertThrowsError(try store.create(name: " work "))
        let file = store.root.appendingPathComponent("profiles.json")
        try Data("corrupt".utf8).write(to: file)
        let broken = ChromeProfiles(root: store.root, hostManifest: store.hostManifest)
        XCTAssertNotNil(broken.loadError)
        XCTAssertThrowsError(try broken.create(name: "New"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "corrupt")
    }
}

extension ChromeProfilesTests {
    func testLiveManagedInstanceBrowser() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let kindValue = env["DOPPEL_MANAGED_BROWSER_QA_KIND"],
              let kind = InstanceApp(rawValue: kindValue), let slug = env["DOPPEL_MANAGED_BROWSER_QA_SLUG"] else {
            throw XCTSkip("Opt-in owned-browser launch using an existing managed instance and a disposable browser store.")
        }
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("bin/doppel")
        let process = Process()
        process.executableURL = cli
        process.arguments = kind.cliPrefix + ["list", "--porcelain"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let owner = try XCTUnwrap(InstanceStore.parsePorcelain(String(decoding: data, as: UTF8.self), appKind: kind)
            .first(where: { $0.id == kind.instanceID(slug) }))
        XCTAssertTrue(owner.agentHome?.hasPrefix("/") == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browsers = ChromeProfiles(root: root)
        let profile = try browsers.ensureProfile(for: owner)
        XCTAssertEqual(profile.ownerID, owner.id)
        XCTAssertFalse(profile.accountConfirmed ?? true)
        let opened = expectation(description: "Managed instance browser opened for sign-in")
        browsers.launch(profile, setup: true, signInOnly: true) { error in
            XCTAssertNil(error)
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 20)
        let otherAccount = instance(owner.id, name: owner.name, kind: kind, home: root.appendingPathComponent("different-account").path)
        XCTAssertThrowsError(try browsers.ensureProfile(for: otherAccount), "A running browser must not silently change accounts")
        XCTAssertEqual(browsers.profile(for: owner)?.ownerAgentHome, owner.agentHome)
        print("OWNED_BROWSER_QA_ROOT=\(root.path)")
        print("OWNED_BROWSER_QA_INSTANCE=\(owner.id)")
    }

    func testLiveClaudeCodeSetup() async throws {
        guard ProcessInfo.processInfo.environment["DOPPEL_CLAUDE_CHROME_QA"] == "1" else {
            throw XCTSkip("Opt-in Claude Code native-host setup in a fresh disposable profile.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let live = ChromeProfiles(root: root)
        let profile = try live.create(name: "Doppel Claude Code QA", bridges: [.claude])
        try live.prepare(profile)
        let launched = expectation(description: "Claude Code QA browser opened")
        live.launch(profile, setup: true) { error in
            XCTAssertNil(error)
            launched.fulfill()
        }
        await fulfillment(of: [launched], timeout: 20)
        print("CLAUDE_CHROME_QA_ROOT=\(root.path)")
        print("CLAUDE_CHROME_QA_PROFILE=\(live.directory(profile).path)")
    }

    func testLiveIsolatedLaunch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["DOPPEL_CHROME_QA_SOURCE"],
              let idA = env["DOPPEL_CHROME_QA_A"], let idB = env["DOPPEL_CHROME_QA_B"] else {
            throw XCTSkip("Opt-in real Chrome profile launch with disposable browser fixtures.")
        }
        let (store, _) = try fixture()
        // Use the real installed host, while keeping all writes in the QA root.
        let savedRoot = env["DOPPEL_CHROME_QA_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let live = ChromeProfiles(root: savedRoot ?? store.root)
        for (name, id) in [("A", idA), ("B", idB)] {
            let profile: ChromeProfile
            if let existing = live.profiles.first(where: { $0.name == "Doppel Live QA " + name }) {
                profile = existing
            } else {
                profile = try live.create(name: "Doppel Live QA " + name)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent(name),
                                                 to: live.directory(profile))
                try live.pair(profile, id: id)
            }
            try live.prepare(profile)
            let launched = expectation(description: "Chrome opened " + name)
            live.launch(profile) { error in
                XCTAssertNil(error)
                launched.fulfill()
            }
            await fulfillment(of: [launched], timeout: 20)
        }
        print("CHROME_QA_ROOT=\(live.root.path)")
        XCTAssertEqual(live.profiles.count, 2)
    }
}
