import XCTest
import Foundation
@testable import DoppelRemoteCore

final class RemoteConfigurationTests: XCTestCase {
    func testPrivateAddressBoundaries() {
        for address in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.255"] {
            XCTAssertTrue(RemoteNetworkAddress.isPrivate(address), address)
        }
        for address in ["0.0.0.0", "127.0.0.1", "8.8.8.8", "172.32.0.1", "100.128.0.1", "010.0.0.1", "10.0.0.256", "::1"] {
            XCTAssertFalse(RemoteNetworkAddress.isPrivate(address), address)
        }
    }

    func testIdentifiersCannotSelectArbitraryPaths() throws {
        let store = RemoteConfigurationStore()
        for id in ["../a", "/private/tmp", "ABCDEFGHIJKL", "12345678901", "1234567890123"] {
            XCTAssertThrowsError(try store.directory(id))
        }
        XCTAssertEqual(try store.directory("012345abcdef").lastPathComponent, "012345abcdef")
    }

    func testCanonicalSocketLengthBlocksLongHome() {
        let root = URL(fileURLWithPath: "/Users/" + String(repeating: "a", count: 90) + "/.dpr")
        XCTAssertThrowsError(try RemoteConfigurationStore(root: root).validateHomeLength("012345abcdef"))
    }

    func testSharedWritableOrSymlinkFilesAreRejected() throws {
        // Keep the generated fixture for inspection; no unrelated file is removed.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doppel-permissions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = RemoteConfigurationStore(root: root)
        XCTAssertNoThrow(try store.validate(root, privateMode: true))
        let shared = root.appendingPathComponent("shared")
        try Data().write(to: shared)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: shared.path)
        XCTAssertThrowsError(try store.validate(shared))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try store.validate(link))
    }
}
