import Foundation

enum VendorUpdateState: String {
    case available
    case ready
    /// The primary is current but managed instances were built from an older
    /// vendor build, which is what the vendor's own updater leaves behind when
    /// it installs a build on its own. There is nothing to download; the
    /// instances are rebuilt from the app already installed. The only state a
    /// Claude check ever offers, since Claude always updates itself.
    case staleInstances = "stale-instances"
}

/// What `doppel [--app claude] update check --porcelain` offers for one vendor
/// app. Builds are kept as text: ChatGPT's are integers, Claude's are dotted
/// (4.4212.0), and both compare numerically component by component.
struct VendorUpdate: Equatable {
    let app: InstanceApp
    let state: VendorUpdateState
    let currentBuild: String
    let currentVersion: String
    let targetBuild: String
    let targetVersion: String
    /// Instances known to be behind, reported only for `.staleInstances`.
    let staleInstanceCount: Int

    init(app: InstanceApp = .chatgpt, state: VendorUpdateState, currentBuild: String, currentVersion: String,
         targetBuild: String, targetVersion: String, staleInstanceCount: Int) {
        self.app = app
        self.state = state
        self.currentBuild = currentBuild
        self.currentVersion = currentVersion
        self.targetBuild = targetBuild
        self.targetVersion = targetVersion
        self.staleInstanceCount = staleInstanceCount
    }

    /// Stable tab-separated output from `doppel update check --porcelain`.
    /// A current, malformed, or backwards result deliberately produces no
    /// prompt.
    static func parse(_ output: String, app: InstanceApp = .chatgpt) -> VendorUpdate? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6,
              let state = VendorUpdateState(rawValue: String(fields[0])),
              isBuild(fields[1]), isBuild(fields[3])
        else { return nil }
        let currentBuild = String(fields[1]), feedBuild = String(fields[3])
        switch state {
        case .available, .ready:
            // Doppel never downloads Claude, so a Claude line claiming one is
            // not something to act on.
            guard app == .chatgpt, isBuild(feedBuild, newerThan: currentBuild) else { return nil }
            return VendorUpdate(
                app: app,
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
            return VendorUpdate(
                app: app,
                state: state,
                currentBuild: currentBuild,
                currentVersion: String(fields[2]),
                targetBuild: currentBuild,
                targetVersion: String(fields[2]),
                staleInstanceCount: stale)
        }
    }

    static func isBuild<S: StringProtocol>(_ text: S) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
    }

    static func isBuild(_ candidate: String, newerThan other: String) -> Bool {
        candidate.compare(other, options: .numeric) == .orderedDescending
    }
}

/// The vendor build Doppel currently sees installed, read from the same
/// porcelain line as the update decision.
///
/// Deliberately separate from `VendorUpdate.parse`, which reports nothing when
/// there is no update to offer. A Mac that is up to date must raise no prompt
/// and still has a version worth showing, so the two questions are answered by
/// two parsers over one line rather than by loosening the prompt rule.
struct InstalledVendor: Equatable {
    var app: InstanceApp = .chatgpt
    let build: String
    let version: String

    /// Claude's build and version are the same string, which would read twice.
    var display: String { build == version ? version : "\(version) (\(build))" }

    static func parse(_ output: String, app: InstanceApp = .chatgpt) -> InstalledVendor? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        // The leading state word is what identifies this as an update-check
        // line; without it a stray row could be read as a version.
        guard fields.count >= 3,
              ["current", "available", "ready", "stale-instances"].contains(String(fields[0])),
              VendorUpdate.isBuild(fields[1]),
              !fields[2].isEmpty
        else { return nil }
        return InstalledVendor(app: app, build: String(fields[1]), version: String(fields[2]))
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
