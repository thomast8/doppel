import XCTest
@testable import DoppelMenuBar

final class PanelStateTests: XCTestCase {
    private func issue(_ permission: String, _ status: String) -> PermissionIssue {
        PermissionIssue(instanceID: "work", instanceName: "ChatGPT Work",
                        permission: permission, status: status)
    }

    func testRowActivityPrefersWorkOverEverythingElse() {
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: true,
                                               issues: [issue("microphone", "denied")], running: true),
                       .working)
    }

    func testRowActivityNamesASingleDenial() {
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false,
                                               issues: [issue("microphone", "denied")], running: true),
                       .attention("Microphone access denied"))
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false,
                                               issues: [issue("camera", "restricted")], running: false),
                       .attention("Camera access restricted"))
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false,
                                               issues: [issue("permission-check", "outdated")], running: false),
                       .checkerOutdated)
    }

    func testRowActivityCountsSeveralIssues() {
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false,
                                               issues: [issue("microphone", "denied"), issue("camera", "denied")],
                                               running: false),
                       .attention("2 permissions need attention"))
    }

    func testRowActivityOnlyCountsIssuesThatNeedAttention() {
        // The panel is handed every status row; an unasked camera is not a fault.
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false,
                                               issues: [issue("camera", "not-requested")], running: true),
                       .running)
    }

    func testRowActivityReportsRunningStoppedAndMissing() {
        XCTAssertEqual(InstanceActivity.derive(installed: true, busy: false, issues: [], running: false), .stopped)
        XCTAssertEqual(InstanceActivity.derive(installed: false, busy: false, issues: [], running: false),
                       .notInstalled)
    }

    func testSetupProgressResumesAtTheFirstMissingStep() {
        XCTAssertEqual(SetupProgress(appFound: false, signingReady: false, hasInstance: false).resumeStep,
                       .findApp)
        XCTAssertEqual(SetupProgress(appFound: true, signingReady: false, hasInstance: true).resumeStep,
                       .signing)
        XCTAssertEqual(SetupProgress(appFound: true, signingReady: true, hasInstance: false).resumeStep,
                       .create)
        let done = SetupProgress(appFound: true, signingReady: true, hasInstance: true)
        XCTAssertTrue(done.isComplete)
        XCTAssertFalse(SetupProgress(appFound: true, signingReady: false, hasInstance: true).isComplete)
    }

    func testOnboardingOnlyOpensItselfOnceForAnEmptyMac() {
        XCTAssertTrue(SetupProgress.shouldAutoOpen(listLoaded: true, instanceCount: 0, alreadyShown: false))
        XCTAssertFalse(SetupProgress.shouldAutoOpen(listLoaded: false, instanceCount: 0, alreadyShown: false),
                       "an empty list before the CLI answers is not an empty Mac")
        XCTAssertFalse(SetupProgress.shouldAutoOpen(listLoaded: true, instanceCount: 2, alreadyShown: false))
        XCTAssertFalse(SetupProgress.shouldAutoOpen(listLoaded: true, instanceCount: 0, alreadyShown: true))
    }

    func testUpdateHeadlineMatchesWhatTheButtonWillDo() {
        let ready = ChatGPTUpdate(state: .ready, currentBuild: 1, currentVersion: "1.0",
                                  targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 0)
        let available = ChatGPTUpdate(state: .available, currentBuild: 1, currentVersion: "1.0",
                                      targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 0)
        let stale = ChatGPTUpdate(state: .staleInstances, currentBuild: 2, currentVersion: "1.1",
                                  targetBuild: 2, targetVersion: "1.1", staleInstanceCount: 1)
        XCTAssertEqual(MenuContent.updateHeadline(ready), "ChatGPT 1.1 is ready to install")
        XCTAssertEqual(MenuContent.updateHeadline(available), "ChatGPT 1.1 is available")
        XCTAssertEqual(MenuContent.updateHeadline(stale), "1 instance is out of date")
    }

    func testRunningMatchUsesTheStandardisedBundlePath() {
        XCTAssertTrue(InstanceStore.pathsMatch("/Applications/ChatGPT Work.app/",
                                               "/Applications/ChatGPT Work.app"))
        XCTAssertFalse(InstanceStore.pathsMatch("/Applications/ChatGPT.app",
                                                "/Applications/ChatGPT Work.app"))
        XCTAssertFalse(InstanceStore.pathsMatch("", ""), "an instance with no path is never running")
    }

    func testAnEmptyNameCreatesTheSuggestedOne() {
        XCTAssertEqual(OnboardingView.instanceName(typed: "  ", kind: .chatgpt), "ChatGPT Work",
                       "the button offers the suggestion, so pressing it must create that")
        XCTAssertEqual(OnboardingView.instanceName(typed: "", kind: .claude), "Claude Work")
        XCTAssertEqual(OnboardingView.instanceName(typed: " Research ", kind: .claude), "Research")
    }
}
