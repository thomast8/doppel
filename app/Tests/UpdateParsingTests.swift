import Foundation

@main enum UpdateParsingTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
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
        print("Update and permission parsing tests passed")
    }
}
