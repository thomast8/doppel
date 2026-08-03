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

        let permissions = PermissionIssue.parse("""
            personal\tChatGPT Personal\tmicrophone\tdenied
            personal\tChatGPT Personal\tcamera\tgranted
            veridue\tChatGPT Veridue\tpermission-check\toutdated
            """)
        expect(permissions.count == 2, "only non-granted permission rows should become issues")
        expect(permissions[0].label == "Microphone", "permission keys should have user-facing labels")
        expect(permissions[0].canRequest, "ordinary permissions should be requestable")
        expect(!permissions[1].canRequest, "an outdated checker must require a rebuild")
        print("Update and permission parsing tests passed")
    }
}
