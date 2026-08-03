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
