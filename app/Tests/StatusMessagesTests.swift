import XCTest
@testable import DoppelMenuBar

final class StatusMessagesTests: XCTestCase {
    private let available = VendorUpdate(state: .available, currentBuild: "1", currentVersion: "1.0",
                                          targetBuild: "2", targetVersion: "1.1", staleInstanceCount: 0)
    private let ready = VendorUpdate(state: .ready, currentBuild: "1", currentVersion: "1.0",
                                      targetBuild: "2", targetVersion: "1.1", staleInstanceCount: 0)
    private let stale = VendorUpdate(state: .staleInstances, currentBuild: "2", currentVersion: "1.1",
                                      targetBuild: "2", targetVersion: "1.1", staleInstanceCount: 2)
    private let claudeStale = VendorUpdate(app: .claude, state: .staleInstances, currentBuild: "4.4212.0",
                                           currentVersion: "4.4212.0", targetBuild: "4.4212.0",
                                           targetVersion: "4.4212.0", staleInstanceCount: 1)

    func testProgressNamesThePhaseThatIsActuallyRunning() {
        XCTAssertEqual(StatusMessages.progress(for: available), "Downloading and verifying ChatGPT 1.1…")
        XCTAssertEqual(StatusMessages.progress(for: ready),
                       "Installing ChatGPT 1.1 and rebuilding every instance…")
        XCTAssertEqual(StatusMessages.progress(for: stale), "Rebuilding 2 outdated ChatGPT instances…")
        XCTAssertEqual(StatusMessages.progress(for: claudeStale), "Rebuilding 1 outdated Claude instance…")
    }

    func testOfferNotificationSaysWhereToAct() {
        XCTAssertEqual(StatusMessages.offer(available).title, "ChatGPT 1.1 is available")
        XCTAssertEqual(StatusMessages.offer(ready).title, "ChatGPT 1.1 is ready to install")
        XCTAssertEqual(StatusMessages.offer(stale).title, "2 ChatGPT instances are out of date")
        XCTAssertEqual(StatusMessages.offer(claudeStale).title, "1 Claude instance is out of date")
        XCTAssertTrue(StatusMessages.offer(ready).body.contains("Doppel menu bar"))
    }

    func testCompletionOnlyClaimsWhatTheRunReported() {
        let updated = StatusMessages.completion(ready, output: "updated\t1\t2\t3\t2\n", signingReady: true)
        XCTAssertEqual(updated.title, "ChatGPT 1.1 installed")
        XCTAssertEqual(updated.body, "Doppel verified 3 instances and reopened 2.")

        let reconciled = StatusMessages.completion(stale, output: "reconciled\t2\t2\t2\t1\n", signingReady: true)
        XCTAssertEqual(reconciled.title, "ChatGPT instances rebuilt",
                       "a reconcile installs nothing and must not say it did")

        let claude = StatusMessages.completion(claudeStale, output: "reconciled\t4.4212.0\t4.4212.0\t1\t1\n",
                                               signingReady: true)
        XCTAssertEqual(claude.title, "Claude instances rebuilt")
        XCTAssertEqual(claude.body, "Doppel rebuilt 1 instances from Claude 4.4212.0 and reopened 1.")

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

final class CLIProgressTests: XCTestCase {
    func testParsesAProgressLine() {
        XCTAssertEqual(CLIProgress.parse("doppel-progress\t42\tDownloading ChatGPT 1.1"),
                       CLIProgress(fraction: 0.42, label: "Downloading ChatGPT 1.1"))
    }

    func testClampsAndRejectsMalformedLines() {
        XCTAssertEqual(CLIProgress.parse("doppel-progress\t140\tDone")?.fraction, 1)
        XCTAssertNil(CLIProgress.parse("doppel-progress\tabc\tDone"))
        XCTAssertNil(CLIProgress.parse("doppel: something failed"))
        XCTAssertNil(CLIProgress.parse("doppel-progress\t10"))
    }

    func testErrorTextLeavesProgressLinesOut() {
        let stderr = "doppel-progress\t10\tPreparing\ndoppel: the rebuild failed\ndoppel-progress\t20\tSigning\n"
        XCTAssertEqual(CLIProgress.withoutProgress(stderr), "doppel: the rebuild failed")
    }
}
