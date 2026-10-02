import XCTest
import Foundation
import CryptoKit
@testable import DoppelRemoteCore

final class RemoteControllerTests: XCTestCase {
    func testGeneratedAndReencodedPhoneKeysLoadInAppleParser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doppel-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let generated = root.appendingPathComponent("generated.pem")
        try RemoteAccessController.generatePhoneKey(at: generated)
        let generatedText = try String(contentsOf: generated, encoding: .utf8)
        XCTAssertNoThrow(try P256.Signing.PrivateKey(pemRepresentation: generatedText))
        try assertNamedP256(generated)
        let legacy = root.appendingPathComponent("legacy.pem")
        _ = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", "256", "-m", "PEM", "-N", "", "-f", legacy.path], message: "Fixture key generation failed.")
        let before = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", legacy.path], message: "Fixture validation failed.")
        try RemoteAccessController.encodePhoneKey(at: legacy)
        let encodedText = try String(contentsOf: legacy, encoding: .utf8)
        XCTAssertNoThrow(try P256.Signing.PrivateKey(pemRepresentation: encodedText))
        try assertNamedP256(legacy)
        let after = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", legacy.path], message: "Encoded fixture validation failed.")
        XCTAssertEqual(before, after)
    }

    func testExplicitCurvePKCS8IsNormalizedWithoutChangingAuthorization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doppel-explicit-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = root.appendingPathComponent("explicit.pem")
        _ = try RemoteSystem.requireSuccess("/usr/bin/openssl", ["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:explicit", "-out", key.path], message: "Fixture generation failed.")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        XCTAssertTrue(try String(contentsOf: key, encoding: .utf8).hasPrefix("-----BEGIN PRIVATE KEY-----"))
        let before = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", key.path], message: "Fixture validation failed.")
        try RemoteAccessController.encodePhoneKey(at: key)
        try assertNamedP256(key)
        let after = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", key.path], message: "Encoded fixture validation failed.")
        XCTAssertEqual(before, after)
        XCTAssertNoThrow(try P256.Signing.PrivateKey(pemRepresentation: String(contentsOf: key, encoding: .utf8)))
    }

    private func assertNamedP256(_ key: URL) throws {
        let encoding = try RemoteSystem.requireSuccess("/usr/bin/openssl", ["asn1parse", "-in", key.path], message: "Fixture encoding inspection failed.")
        let text = String(decoding: encoding, as: UTF8.self)
        XCTAssertTrue(text.contains(":prime256v1"))
        XCTAssertFalse(text.contains(":prime-field"))
    }

    func testProcessArgumentsAndExitStatusStayIntact() throws {
        let arguments = ["two words", "a'quote", "$CODEX_HOME"]
        let result = try RemoteSystem.run("/usr/bin/printf", ["%s\n"] + arguments)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), arguments.joined(separator: "\n") + "\n")
        let failure = try RemoteSystem.run("/bin/sh", ["-c", "exit 37"])
        XCTAssertEqual(failure.status, 37)
    }

    func testEnvironmentUsesOnlyTheSelectedHome() {
        let home = URL(fileURLWithPath: "/private/tmp/isolated-home")
        let bin = home.appendingPathComponent("packages/app-server-daemon/current/bin")
        let environment = RemoteSystem.environment(home: home, installDirectory: bin)
        XCTAssertEqual(environment["CODEX_HOME"], home.path)
        XCTAssertEqual(environment["CODEX_INSTALL_DIR"], bin.path)
        XCTAssertTrue(environment["PATH"]?.hasPrefix(bin.path + ":") == true)
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CODEX_EXEC_SERVER_URL"])
        XCTAssertNil(environment["SSH_ORIGINAL_COMMAND"])
    }

    func testExitedProcessCannotHangOnInheritedOutputPipe() throws {
        let start = Date()
        let result = try RemoteSystem.run("/bin/sh", ["-c", "sleep 3 & exit 0"], timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testOptInRealManagedBootstrapFailsClosedWithoutAccount() async throws {
        guard ProcessInfo.processInfo.environment["DOPPEL_REMOTE_BOOTSTRAP_CHECK"] == "1",
              ProcessInfo.processInfo.environment["DOPPEL_DEV"] == "1" else {
            throw XCTSkip("Opt-in isolated vendor-runtime bootstrap check.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/dpr-q-" + UUID().uuidString.prefix(8))
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let profileDirectory = root.appendingPathComponent("profile")
        try fm.createDirectory(at: profileDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let profileFile = profileDirectory.appendingPathComponent("instance-config.zsh")
        try Data().write(to: profileFile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileFile.path)
        let store = RemoteConfigurationStore(root: root)
        let context = RemoteProfileContext(slug: "isolated-check", profileDirectory: profileDirectory.path,
            desktopHome: root.appendingPathComponent("unused-desktop-home").path,
            primaryApp: "/Applications/ChatGPT.app", cliPath: "/unused-test-cli")
        let controller = RemoteAccessController(store: store, profile: context)
        guard let address = RemoteNetworkAddress.available().first?.address else { throw XCTSkip("A private Mac address is required.") }
        try controller.configure(address: address, host: nil)
        let config = try XCTUnwrap(store.find(profileSlug: context.slug))
        let home = try store.home(config.remoteId)
        defer {
            let binary = home.appendingPathComponent("packages/app-server-daemon/current/bin/codex")
            _ = try? RemoteSystem.run(binary.path, ["app-server", "daemon", "stop"],
                environment: RemoteSystem.environment(home: home, installDirectory: binary.deletingLastPathComponent()), timeout: 75)
        }
        do {
            try await controller.enable()
            XCTFail("An unauthenticated runtime must never enable SSH.")
        } catch {
            XCTAssertTrue((error as? RemoteAccessError)?.message.contains("Sign in") == true)
        }
        let directory = try store.directory(config.remoteId)
        XCTAssertFalse(try store.load(config.remoteId).enabled)
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("authorized_keys").path))
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("sshd_config").path))
        XCTAssertTrue(fm.isExecutableFile(atPath: home.appendingPathComponent("packages/app-server-daemon/current/bin/codex").path))
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("app-server-daemon/settings.json"))) as? [String: Any]
        XCTAssertEqual((settings?["updater"] as? [String: Any])?["autoUpdateEnabled"] as? Bool, false)
    }
}
