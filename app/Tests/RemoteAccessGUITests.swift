import XCTest
@testable import DoppelMenuBar

final class RemoteAccessGUITests: XCTestCase {
    @MainActor
    func testLoginCodeCopiesAndRestoresOnlyItsOwnedClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous clipboard", forType: .string)
        let model = RemoteAccessModel()
        model.userCode = "TEST-CODE"
        model.copyLoginCode(pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "TEST-CODE")
        model.restoreClipboard(pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
        model.copyLoginCode(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("user copied something else", forType: .string)
        model.restoreClipboard(pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied something else")
    }

    @MainActor
    func testClipboardRestoresAllOriginalItems() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let original = ["first", "second"].map { value in
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            return item
        }
        pasteboard.writeObjects(original)
        var snapshot = RemoteClipboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("test copied key", forType: .string)
        snapshot.claimCurrentContents(pasteboard, expectedString: "test copied key")
        snapshot.restoreIfOwned(pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }, ["first", "second"])
    }

    @MainActor
    func testCopyFingerprintUsesOwnedClipboardRestore() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous clipboard", forType: .string)
        let model = RemoteAccessModel()
        model.copyFingerprint("SHA256:host-key", pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "SHA256:host-key")
        model.restoreClipboard(pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
    }

    func testParsesReadyStatusAndNetworks() throws {
        let json = #"{"schemaVersion":1,"profileSlug":"personal","remoteId":"012345abcdef","state":"ready","enabled":true,"host":"mac.mesh","bindAddress":"192.168.1.20","port":54221,"username":"thomas","email":"t@example.com","accountId":"workspace-1","runtimeVersion":"1.2","hostKeyFingerprint":"SHA256:abc","checkedAt":"2026-10-01T10:00:00Z","networks":[{"interface":"en0","address":"192.168.1.20"}]}"#
        let status = try RemoteAccessStatus.parse(Data(json.utf8))
        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.accountId, "workspace-1")
        XCTAssertEqual(status.networks, [.init(interface: "en0", address: "192.168.1.20")])
        XCTAssertTrue(RemoteAccessModel.canEnable(status, selectedAddress: "192.168.1.20", identityConfirmed: true))
        XCTAssertFalse(RemoteAccessModel.canEnable(status, selectedAddress: "192.168.1.20", identityConfirmed: false))
        XCTAssertFalse(RemoteAccessModel.canEnable(status, selectedAddress: "192.168.1.21", identityConfirmed: true))
    }

    func testRejectsUnsupportedStatusVersion() {
        let json = #"{"schemaVersion":2,"profileSlug":"personal","state":"ready","enabled":true,"networks":[]}"#
        XCTAssertThrowsError(try RemoteAccessStatus.parse(Data(json.utf8)))
    }

    func testHelperErrorsRequireVersionedSanitizedJSON() {
        let safe = Data("noise\n{\"schemaVersion\":1,\"error\":\"The selected private address is unavailable.\"}\n".utf8)
        XCTAssertEqual(RemoteCLIError.helperMessage(from: safe), "The selected private address is unavailable.")
        XCTAssertNil(RemoteCLIError.helperMessage(from: Data("{\"schemaVersion\":2,\"error\":\"bad\"}".utf8)))
        XCTAssertNil(RemoteCLIError.helperMessage(from: Data("{\"schemaVersion\":1,\"error\":\"/Users/name/private\"}".utf8)))
    }

    func testClipboardRestoresOnlyWhileCopyStillOwnsPasteboard() {
        XCTAssertTrue(RemoteClipboardSnapshot.owns(changeCount: 5, expected: 5,
                                                    currentValue: "private key", expectedValue: "private key"))
        XCTAssertFalse(RemoteClipboardSnapshot.owns(changeCount: 6, expected: 5,
                                                     currentValue: "private key", expectedValue: "private key"))
        XCTAssertFalse(RemoteClipboardSnapshot.owns(changeCount: 5, expected: 5,
                                                     currentValue: "copied details", expectedValue: "private key"))
        XCTAssertFalse(RemoteClipboardSnapshot.owns(changeCount: 5, expected: nil,
                                                     currentValue: "private key", expectedValue: "private key"))
    }

    func testNDJSONWaitsForNewlineAcrossChunks() throws {
        var buffer = NDJSONLineBuffer()
        XCTAssertEqual(try XCTUnwrap(buffer.append(Data(#"{"event":"device"}"#.utf8), maximumBytes: 100)), [])
        XCTAssertEqual(try XCTUnwrap(buffer.append(Data("\n{\"event\":\"complete\"}\n".utf8), maximumBytes: 100)),
                       [#"{"event":"device"}"#, #"{"event":"complete"}"#])
        XCTAssertNil(buffer.append(Data(repeating: 0x78, count: 101), maximumBytes: 100))
    }

    @MainActor
    func testInstanceStoreRetainsProcessUntilCompletionReleasesIt() {
        let store = InstanceStore(testingWithoutStartup: true)
        let id = UUID()
        var process: RemoteCLIProcess? = RemoteCLIProcess()
        weak var weakProcess = process
        store.retainRemoteProcess(process!, id: id)
        process = nil
        XCTAssertNotNil(weakProcess)
        XCTAssertEqual(store.activeRemoteProcessCount, 1)
        store.releaseRemoteProcess(id)
        XCTAssertNil(weakProcess)
        XCTAssertEqual(store.activeRemoteProcessCount, 0)
    }

    func testFirstTimeProfileCannotSignInUntilNetworkIsConfigured() throws {
        let fresh = #"{"schemaVersion":1,"profileSlug":"personal","state":"notConfigured","enabled":false,"networks":[{"interface":"en0","address":"192.168.1.20"}]}"#
        let saved = #"{"schemaVersion":1,"profileSlug":"personal","remoteId":"012345abcdef","state":"signInRequired","enabled":false,"bindAddress":"192.168.1.20","networks":[{"interface":"en0","address":"192.168.1.20"}]}"#
        let freshStatus = try RemoteAccessStatus.parse(Data(fresh.utf8))
        let savedStatus = try RemoteAccessStatus.parse(Data(saved.utf8))
        XCTAssertFalse(RemoteAccessModel.hasConfiguredNetwork(freshStatus, selectedAddress: "192.168.1.20"))
        XCTAssertTrue(RemoteAccessModel.hasConfiguredNetwork(savedStatus, selectedAddress: "192.168.1.20"))
    }

    func testDisruptiveActionRestoresOnlyAnOriginallyEnabledState() {
        XCTAssertTrue(RemoteAccessModel.shouldRestoreAfterDisruption(wasEnabled: true))
        XCTAssertFalse(RemoteAccessModel.shouldRestoreAfterDisruption(wasEnabled: false))
    }

    func testPrivateKeyMustBeECDSAPEM() {
        XCTAssertTrue(RemoteAccessKey.isECDSAPrivateKey("-----BEGIN EC PRIVATE KEY-----\ndata\n-----END EC PRIVATE KEY-----"))
        XCTAssertTrue(RemoteAccessKey.isECDSAPrivateKey("-----BEGIN PRIVATE KEY-----\ndata\n-----END PRIVATE KEY-----"))
        XCTAssertFalse(RemoteAccessKey.isECDSAPrivateKey("-----BEGIN OPENSSH PRIVATE KEY-----\ndata\n-----END OPENSSH PRIVATE KEY-----"))
    }
}
