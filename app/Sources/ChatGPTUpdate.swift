import Foundation

enum ChatGPTUpdateState: String {
    case available
    case ready
    /// The primary is current but managed instances were built from an older
    /// vendor build, which is what ChatGPT's own updater leaves behind when it
    /// installs a build on its own. There is nothing to download; the
    /// instances are rebuilt from the app already installed.
    case staleInstances = "stale-instances"
}

struct ChatGPTUpdate: Equatable {
    let state: ChatGPTUpdateState
    let currentBuild: Int
    let currentVersion: String
    let targetBuild: Int
    let targetVersion: String
    /// Instances known to be behind, reported only for `.staleInstances`.
    let staleInstanceCount: Int

    /// Stable tab-separated output from `doppel update check --porcelain`.
    /// A current, malformed, or backwards result deliberately produces no
    /// prompt.
    static func parse(_ output: String) -> ChatGPTUpdate? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6,
              let state = ChatGPTUpdateState(rawValue: String(fields[0])),
              let currentBuild = Int(fields[1]),
              let feedBuild = Int(fields[3])
        else { return nil }
        switch state {
        case .available, .ready:
            guard feedBuild > currentBuild else { return nil }
            return ChatGPTUpdate(
                state: state,
                currentBuild: currentBuild,
                currentVersion: String(fields[2]),
                targetBuild: feedBuild,
                targetVersion: String(fields[4]),
                staleInstanceCount: 0)
        case .staleInstances:
            // A reconcile rebuilds the instances from the installed primary, so
            // the build to apply is the one already on this Mac rather than the
            // feed's. Without a count there is nothing to rebuild and no reason
            // to interrupt anyone.
            guard fields.count >= 7, let stale = Int(fields[6]), stale > 0 else { return nil }
            return ChatGPTUpdate(
                state: state,
                currentBuild: currentBuild,
                currentVersion: String(fields[2]),
                targetBuild: currentBuild,
                targetVersion: String(fields[2]),
                staleInstanceCount: stale)
        }
    }
}

/// Managed app bundles installed on disk that Doppel's registry does not
/// account for, read from the same porcelain line.
///
/// An instance keeps a full copy of its own definition inside its bundle, so a
/// registry directory can go missing without the app going anywhere. Every
/// inventory-driven command then reports an empty Mac — including `update
/// apply`, which refuses the update this app had just offered. The count is
/// what tells those two emptinesses apart.
struct UnregisteredInstances: Equatable {
    let count: Int

    static func parse(_ output: String) -> UnregisteredInstances? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        // Column nine, so a CLI older than this app reports nothing rather
        // than having its drift counts read as an orphan count.
        guard fields.count >= 9,
              ["current", "available", "ready", "stale-instances"].contains(String(fields[0])),
              let count = Int(fields[8])
        else { return nil }
        return UnregisteredInstances(count: count)
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
              ["current", "available", "ready", "stale-instances"].contains(String(fields[0])),
              let build = Int(fields[1]),
              !fields[2].isEmpty
        else { return nil }
        return InstalledChatGPT(build: build, version: String(fields[2]))
    }
}
