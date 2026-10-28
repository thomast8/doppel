import Foundation

/// What one instance row in the panel says about itself. Derived from state the
/// store already has, so the row cannot claim progress or health the CLI never
/// reported.
enum InstanceActivity: Equatable {
    case working
    case attention(String)
    /// The only fix for an outdated permission checker is a rebuild, so the
    /// row offers that instead of the permissions it cannot read.
    case checkerOutdated
    case running
    case stopped
    case notInstalled

    static func derive(installed: Bool, busy: Bool, issues: [PermissionIssue],
                       running: Bool) -> InstanceActivity {
        if busy { return .working }
        let open = issues.filter(\.needsAttention)
        if open.count > 1 { return .attention("\(open.count) permissions need attention") }
        if let only = open.first {
            switch only.status {
            case "denied": return .attention("\(only.label) access denied")
            case "restricted": return .attention("\(only.label) access restricted")
            default: return .checkerOutdated
            }
        }
        if !installed { return .notInstalled }
        return running ? .running : .stopped
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome, chatGPT, signing, create, permissions, done
}

/// The three things a Mac needs before Doppel is useful. The panel shows them
/// as a checklist until all three hold, and the setup guide resumes at the
/// first one missing.
struct SetupProgress: Equatable {
    let chatGPTFound: Bool
    let signingReady: Bool
    let hasInstance: Bool

    var isComplete: Bool { chatGPTFound && signingReady && hasInstance }

    var resumeStep: OnboardingStep {
        if !chatGPTFound { return .chatGPT }
        if !signingReady { return .signing }
        if !hasInstance { return .create }
        return .done
    }

    static let shownDefaultsKey = "OnboardingShown"

    /// The guide opens by itself once, on a Mac with no instances. After that
    /// the panel's checklist is the way back in, so closing the guide is never
    /// answered by it reappearing at every launch.
    static func shouldAutoOpen(listLoaded: Bool, instanceCount: Int, alreadyShown: Bool) -> Bool {
        listLoaded && instanceCount == 0 && !alreadyShown
    }
}
