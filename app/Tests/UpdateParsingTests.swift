import XCTest
@testable import DoppelMenuBar

// XCTest rather than swift-testing: the Command Line Tools carry Testing's
// swiftmodule but not a loadable Testing.framework, so swift-testing compiles
// there and then fails at launch. Both frameworks need Xcode's toolchain in
// practice, so this uses the mature one. `app/test.zsh` finds a toolchain that
// has it, whatever `xcode-select` happens to point at.
final class UpdateParsingTests: XCTestCase {
    // Kept so every assertion below reads exactly as it did when this was a
    // standalone program. The only change is that a failure now reports its own
    // call site and the run keeps going instead of exiting on the first one.
    private func expect(
        _ condition: @autoclosure () -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    func testUpdateAndPermissionParsing() {
        let installPrompt = DoppelUpdatePromptModel(
            currentVersion: "1.0.9", availableVersion: "1.1.0",
            informationOnly: false, critical: false)
        expect(installPrompt.title == "Doppel 1.1.0 is ready",
               "an installable release should be presented as ready")
        expect(installPrompt.detail.contains("verified before installation"),
               "the prompt must describe the real verification boundary")
        expect(installPrompt.primaryActionTitle == "Install Update",
               "an installable release should offer installation")

        let informationPrompt = DoppelUpdatePromptModel(
            currentVersion: "1.0.9", availableVersion: "2.0",
            informationOnly: true, critical: false)
        expect(informationPrompt.primaryActionTitle == "View Update",
               "an information-only release must not offer an invalid install action")

        let output = "available\t6067\t26.727.40816\t6119\t26.727.51351\thttps://example.invalid/update.zip\n"
        expect(
            ChatGPTUpdate.parse(output) == ChatGPTUpdate(
                state: .available,
                currentBuild: 6067,
                currentVersion: "26.727.40816",
                targetBuild: 6119,
                targetVersion: "26.727.51351"),
            "available update should parse")

        let ready = "ready\t6067\t26.727.40816\t6119\t26.727.51351\thttps://example.invalid/update.zip\n"
        expect(ChatGPTUpdate.parse(ready)?.state == .ready, "prepared update should parse as ready")
        expect(ChatGPTUpdate.parse(
            "current\t6119\t26.727.51351\t6119\t26.727.51351\thttps://example.invalid/update.zip\n") == nil,
            "current build should not prompt")
        expect(ChatGPTUpdate.parse("available\tbroken") == nil, "malformed output should not prompt")
        expect(ChatGPTUpdate.parse(
            "available\t6119\tnewer\t6067\tolder\thttps://example.invalid/update.zip\n") == nil,
            "backwards update should not prompt")

        // The installed build is shown in the menu even when nothing is being
        // offered, so it has to survive the case that produces no prompt.
        expect(InstalledChatGPT.parse(
            "current\t6119\t26.727.51351\t6119\t26.727.51351\thttps://example.invalid/update.zip\n")
            == InstalledChatGPT(build: 6119, version: "26.727.51351"),
            "an up-to-date check should still yield the installed build")
        expect(InstalledChatGPT.parse(output) == InstalledChatGPT(build: 6067, version: "26.727.40816"),
               "an available update should report the build still installed, not the target")
        expect(InstalledChatGPT.parse(ready)?.build == 6067,
               "a prepared update should also report the installed build")
        expect(InstalledChatGPT.parse(output)?.display == "26.727.40816 (6067)",
               "the menu label should read version then build")
        expect(InstalledChatGPT.parse("available\tbroken") == nil,
               "a malformed line should yield no version rather than a wrong one")
        expect(InstalledChatGPT.parse("rollbacks\t3\tsomething") == nil,
               "a row from another command must not be read as a version")
        expect(InstalledChatGPT.parse("current\t6119\t\n") == nil,
               "an empty version field should be rejected")

        // A source build can be missing either version key, and the menu row
        // must still read like a version rather than "Doppel  ()".
        expect(MenuContent.versionLabel(short: "1.0.0", build: "10") == "Doppel 1.0.0 (10)",
               "both keys present should read version then build")
        expect(MenuContent.versionLabel(short: "1.0.0", build: nil) == "Doppel 1.0.0",
               "a missing build should not leave empty parentheses")
        expect(MenuContent.versionLabel(short: nil, build: "10") == "Doppel build 10",
               "a build alone should say so rather than posing as a version")
        expect(MenuContent.versionLabel(short: nil, build: nil) == "Doppel (version unknown)",
               "no version information should be stated plainly")
        expect(MenuContent.versionLabel(short: "  ", build: "") == "Doppel (version unknown)",
               "blank keys should be treated as absent, not printed")

        let permissionOutput = """
            personal\tChatGPT Personal\tmicrophone\tdenied
            personal\tChatGPT Personal\tcamera\tgranted
            veridue\tChatGPT Veridue\tpermission-check\toutdated
            test\tChatGPT Test\tscreen-recording\tunconfirmed
            test\tChatGPT Test\tcamera\tnot-requested
            """
        let statuses = PermissionIssue.parseStatuses(permissionOutput)
        let permissions = PermissionIssue.parse(permissionOutput)
        expect(statuses.count == 5, "every permission row should remain visible in the status submenu")
        expect(permissions.count == 2, "only explicit denials and checker failures should become issues")
        expect(permissions[0].label == "Microphone", "permission keys should have user-facing labels")
        expect(statuses[1].statusLabel == "Granted", "granted permissions should be labelled honestly")
        expect(!statuses[3].needsAttention, "an unconfirmable boolean must not be reported as missing")
        expect(!statuses[4].needsAttention, "an unused optional capability must not raise a warning")
        expect(statuses[0].action == .openSettings,
               "a denied permission must open Settings instead of trying a request that cannot reprompt")
        expect(statuses[1].action == .openSettings,
               "a granted permission row should remain a useful Settings shortcut")
        expect(statuses[2].action == .unavailable,
               "an outdated checker cannot perform a permission action")
        expect(statuses[3].action == .requestNative,
               "an unconfirmed boolean permission should run its native request first")
        expect(statuses[4].action == .requestNative,
               "a not-requested capability must request natively so macOS registers the app")
        expect(!statuses[4].nativeRequestCanStayInconclusive,
               "a conclusive not-requested row must stay retryable, never parked on Settings")
        expect(statuses[3].nativeRequestCanStayInconclusive,
               "a boolean-only check should fall back to Settings after one native attempt")
        expect(statuses[0].settingsURL?.absoluteString.contains("Privacy_Microphone") == true,
               "permission rows should open their exact System Settings pane")
        let notification = PermissionIssue(
            instanceID: "personal", instanceName: "ChatGPT Personal",
            permission: "notifications", status: "granted")
        expect(notification.settingsURL?.absoluteString.contains("Notifications-Settings") == true,
               "a granted Notifications row must remain actionable rather than greyed out")
        let exactPanes = [
            "accessibility": "Privacy_Accessibility",
            "screen-recording": "Privacy_ScreenCapture",
            "microphone": "Privacy_Microphone",
            "camera": "Privacy_Camera",
            "notifications": "Notifications-Settings",
        ]
        for (key, pane) in exactPanes {
            let row = PermissionIssue(
                instanceID: "test", instanceName: "ChatGPT Test",
                permission: key, status: "denied")
            expect(row.settingsURL?.absoluteString.contains(pane) == true,
                   "\(key) should open its exact Settings pane")
        }
        let unknown = PermissionIssue(
            instanceID: "test", instanceName: "ChatGPT Test",
            permission: "unknown-capability", status: "not-requested")
        expect(unknown.action == .unavailable && unknown.settingsURL == nil,
               "unknown capabilities must never be forwarded to the launcher")

        let nativeTools = NativeToolsStatus.parse("""
            computer-use\tready
            chronicle\trunning\tChatGPT Veridue\t/Users/me/Applications/ChatGPT Veridue.app\t12
            rollbacks\t3
            in-app-browser\tunavailable-in-instances
            browser-host\tChrome\tChatGPT Personal\t/Users/me/.codex-secondary\t/Users/me/Chrome.json
            browser-host\tEdge\tChatGPT Personal\t/Users/me/.codex-secondary\t/Users/me/Edge.json
            instance\tpersonal\tChatGPT Personal\t/Users/me/Applications/ChatGPT Personal.app\tcom.openai.codex.secondary\tyes
            instance\tfresh\tChatGPT Fresh\t/Users/me/Applications/ChatGPT Fresh.app\tcom.openai.codex.fresh\tno
            """)
        expect(nativeTools?.computerUse == .ready, "Computer Use readiness should parse")
        expect(nativeTools?.chronicleHost == "ChatGPT Veridue", "shared Chronicle host should parse")
        expect(nativeTools?.chronicleIsFresh == true, "a recent Chronicle frame should be fresh")
        expect(nativeTools?.discoverableRollbacks == 3, "discoverable rollback count should parse")
        expect(nativeTools?.inAppBrowserUnavailable == true,
               "the in-app browser should report as unavailable in instances")
        expect(nativeTools?.browserHosts.count == 2, "every browser registration should parse")
        expect(nativeTools?.sharedBrowserOwner == "ChatGPT Personal",
               "browsers that agree on an owner should report it once")
        expect(nativeTools?.instancesWithBrowserHost == ["ChatGPT Personal"],
               "only an instance with its own extension host can be offered the registration")
        expect(nativeTools?.browserOwnerNames == ["ChatGPT Personal"],
               "the owner column should resolve to an instance name")

        let assignedIAB = NativeToolsStatus.parse(
            "in-app-browser\tassigned\tpersonal\tChatGPT Personal\trunning\tvalid\n")
        expect(assignedIAB?.inAppBrowserInstanceID == "personal",
               "the built-in-browser engine slot should retain the stable profile id")
        expect(assignedIAB?.inAppBrowserInstanceName == "ChatGPT Personal",
               "the assigned profile should be shown by name")
        expect(assignedIAB?.inAppBrowserRunning == true,
               "a running official engine should remain distinguishable from an assignment")
        expect(assignedIAB?.inAppBrowserVendorValid == true,
               "the menu should surface whether the official engine passed verification")
        expect(assignedIAB?.inAppBrowserUnavailable == false,
               "an assigned vendor engine must not inherit the clone-only unavailable label")

        let unassignedIAB = NativeToolsStatus.parse("in-app-browser\tunassigned\n")
        expect(unassignedIAB != nil && unassignedIAB?.inAppBrowserInstanceName.isEmpty == true,
               "an unassigned engine slot should still be recognized status")

        let instances = InstanceStore.parsePorcelain("""
            personal\tChatGPT Personal\t/Users/me/ChatGPT Personal.app\tinstalled\tA855F7\tvendor
            work\tChatGPT Work\t/Users/me/ChatGPT Work.app\tmissing\t1FA97E\tclone
            legacy\tChatGPT Legacy\t/Users/me/ChatGPT Legacy.app\tinstalled\t
            """)
        expect(instances.count == 3, "new and old list rows should parse together")
        expect(instances[0].usesBuiltInBrowser,
               "a vendor list row should become the built-in-browser engine")
        expect(!instances[1].usesBuiltInBrowser && !instances[2].usesBuiltInBrowser,
               "clone and legacy rows should keep the locally signed engine")

        // Two instances sharing one CODEX_HOME are both named in the column, and
        // neither should then be offered the registration it already holds.
        let shared = NativeToolsStatus.parse(
            "browser-host\tChrome\tChatGPT Veridue, ChatGPT Spare\t/Users/me/.codex\t/Users/me/Chrome.json")
        expect(shared?.browserOwnerNames == ["ChatGPT Veridue", "ChatGPT Spare"],
               "every instance sharing the owning runtime should be recognised")

        // A registration rewritten for one browser but not another is a real
        // state the menu has to distinguish from agreement.
        let split = NativeToolsStatus.parse("""
            computer-use\tidle
            browser-host\tChrome\tChatGPT Personal\t/Users/me/.codex-secondary\t/Users/me/Chrome.json
            browser-host\tEdge\tChatGPT Veridue\t/Users/me/.codex\t/Users/me/Edge.json
            """)
        expect(split?.sharedBrowserOwner == nil, "browsers that disagree should not report one owner")
        expect(split?.browserHosts.count == 2, "both sides of a split should be kept")
        expect(split?.inAppBrowserUnavailable == false,
               "an absent in-app-browser row should not claim unavailability")

        // A row a newer CLI adds must not make the whole status unreadable.
        let future = NativeToolsStatus.parse("computer-use\tready\nsome-new-row\twhatever\n")
        expect(future?.computerUse == .ready, "an unknown row should be skipped, not fatal")
        expect(NativeToolsStatus.parse("nothing-recognizable\there") == nil,
               "output with no known rows should not parse")
    }
}
