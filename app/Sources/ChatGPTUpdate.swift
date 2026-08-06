import Foundation

enum ChatGPTUpdateState: String {
    case available
    case ready
}

struct ChatGPTUpdate: Equatable {
    let state: ChatGPTUpdateState
    let currentBuild: Int
    let currentVersion: String
    let targetBuild: Int
    let targetVersion: String

    /// Stable tab-separated output from `doppel update check --porcelain`.
    /// A current, malformed, or backwards result deliberately produces no
    /// prompt.
    static func parse(_ output: String) -> ChatGPTUpdate? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6,
              let state = ChatGPTUpdateState(rawValue: String(fields[0])),
              let currentBuild = Int(fields[1]),
              let targetBuild = Int(fields[3]),
              targetBuild > currentBuild
        else { return nil }
        return ChatGPTUpdate(
            state: state,
            currentBuild: currentBuild,
            currentVersion: String(fields[2]),
            targetBuild: targetBuild,
            targetVersion: String(fields[4]))
    }
}

/// The vendor build Doppel currently sees installed, read from the same
/// porcelain line as the update decision.
///
/// Deliberately separate from `ChatGPTUpdate.parse`, which reports nothing when
/// there is no update to offer. A Mac that is up to date must raise no prompt
/// and still has a version worth showing, so the two questions are answered by
/// two parsers over one line rather than by loosening the prompt rule.
struct InstalledChatGPT: Equatable {
    let build: Int
    let version: String

    var display: String { "\(version) (\(build))" }

    static func parse(_ output: String) -> InstalledChatGPT? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        // The leading state word is what identifies this as an update-check
        // line; without it a stray row could be read as a version.
        guard fields.count >= 3,
              ["current", "available", "ready"].contains(String(fields[0])),
              let build = Int(fields[1]),
              !fields[2].isEmpty
        else { return nil }
        return InstalledChatGPT(build: build, version: String(fields[2]))
    }
}
