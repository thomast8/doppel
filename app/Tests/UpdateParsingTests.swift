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
        print("Update and permission parsing tests passed")
    }
}
