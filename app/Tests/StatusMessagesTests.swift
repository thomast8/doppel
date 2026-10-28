import XCTest
@testable import DoppelMenuBar

final class StatusMessagesTests: XCTestCase {
    private let available = ChatGPTUpdate(state: .available, currentBuild: 1, currentVersion: "1.0",
                                          targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 0)
    private let ready = ChatGPTUpdate(state: .ready, currentBuild: 1, currentVersion: "1.0",
                                      targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 0)
    private let stale = ChatGPTUpdate(state: .staleInstances, currentBuild: 2, currentVersion: "1.1",
                                      targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 2)

    func testProgressNamesThePhaseThatIsActuallyRunning() {
        XCTAssertEqual(StatusMessages.progress(for: available), "Downloading and verifying ChatGPT 1.1…")
        XCTAssertEqual(StatusMessages.progress(for: ready),
                       "Installing ChatGPT 1.1 and rebuilding every instance…")
        XCTAssertEqual(StatusMessages.progress(for: stale), "Rebuilding 2 outdated instances…")
    }

    func testOfferNotificationSaysWhereToAct() {
        XCTAssertEqual(StatusMessages.offer(available).title, "ChatGPT 1.1 is available")
        XCTAssertEqual(StatusMessages.offer(ready).title, "ChatGPT 1.1 is ready to install")
        XCTAssertEqual(StatusMessages.offer(stale).title, "2 instances are out of date")
        XCTAssertTrue(StatusMessages.offer(ready).body.contains("Doppel menu bar"))
    }

    func testCompletionOnlyClaimsWhatTheRunReported() {
        let updated = StatusMessages.completion(ready, output: "updated\t1\t2\t3\t2\n", signingReady: true)
        XCTAssertEqual(updated.title, "ChatGPT 1.1 installed")
        XCTAssertEqual(updated.body, "Doppel verified 3 instances and reopened 2.")

        let reconciled = StatusMessages.completion(stale, output: "reconciled\t2\t2\t2\t1\n", signingReady: true)
        XCTAssertEqual(reconciled.title, "Instances rebuilt",
                       "a reconcile installs nothing and must not say it did")

        let current = StatusMessages.completion(stale, output: "current\t2\t2\n", signingReady: true)
        XCTAssertEqual(current.title, "Nothing to rebuild")
    }

    func testCompletionWarnsAboutAdHocSigning() {
        let adHoc = StatusMessages.completion(ready, output: "updated\t1\t2\t3\t2\n", signingReady: false)
        XCTAssertTrue(adHoc.body.contains("secure signing"))
    }

    func testCompletionToleratesShortOutput() {
        let bare = StatusMessages.completion(ready, output: "updated\n", signingReady: true)
        XCTAssertEqual(bare.body, "Doppel verified all instances and reopened the ones that were running.")
    }
}
