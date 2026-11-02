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

    func testClaudeOnlySetupAndAddingClaudePreserveChatGPTPairing() throws {
        let (store, root) = try fixture()
        let claudeManifest = root.appendingPathComponent("claude-host.json")
        let host: [String: Any] = ["name": ChromeBridge.claude.hostName, "type": "stdio", "path": "/usr/bin/true",
                                   "allowed_origins": ["chrome-extension://\(ChromeBridge.claude.extensionID)/"]]
        try JSONSerialization.data(withJSONObject: host).write(to: claudeManifest)
        let both = ChromeProfiles(root: store.root, hostManifest: store.hostManifest, claudeHostManifest: claudeManifest)
        let existing = try both.create(name: "Existing")
        let pairID = UUID()
        try both.pair(existing, id: pairID.uuidString)
        let upgraded = try both.addBridge(.claude, to: existing)
        XCTAssertEqual(upgraded.bridgeID, pairID)
        XCTAssertEqual(upgraded.enabledBridges, [.chatgpt, .claude])
        XCTAssertEqual(both.directory(existing), both.directory(upgraded))
        XCTAssertEqual(try Data(contentsOf: both.directory(upgraded).appendingPathComponent(
            "NativeMessagingHosts/" + ChromeBridge.claude.hostName + ".json")), try Data(contentsOf: claudeManifest))
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
