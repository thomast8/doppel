import Foundation

struct NativeToolsStatus: Equatable {
    enum ComputerUseState: String {
        case ready
        case idle
        case unknown
    }

    enum ChronicleState: String {
        case running
        /// A recorder owns Chronicle machine-wide but has not started
        /// capturing, so no app on this Mac has screen history.
        case held
        case stopped
        case unknown
    }

    // One Chromium browser's native-messaging registration, and the app that
    // currently owns it. Only one app can, and every ChatGPT app claims it at
    // launch, so this is the reason an instance can or cannot browse.
    struct BrowserHost: Equatable {
        var browser = ""
        var owner = ""
        var codexHome = ""
        var manifestPath = ""

        /// Instances named in the owner column. Several can share one
        /// CODEX_HOME, in which case the column names all of them.
        var ownerNames: Set<String> {
            Set(owner.components(separatedBy: ", ").filter { !$0.isEmpty })
        }
    }

    var computerUse: ComputerUseState = .unknown
    var chronicle: ChronicleState = .unknown
    var chronicleHost = ""
    var chronicleAppPath = ""
    var chronicleFrameAge: Int?
    var discoverableRollbacks = 0
    /// True only for output from an older CLI that had no vendor-engine slot.
    var inAppBrowserUnavailable = false
    var inAppBrowserInstanceID = ""
    var inAppBrowserInstanceName = ""
    var inAppBrowserAssignmentState = ""
    var inAppBrowserRunning = false
    var inAppBrowserVendorValid = false
    /// The managed profile the live official ChatGPT process actually uses.
    /// This is deliberately separate from the stored assignment: a normal
    /// Dock launch can use the Veridue/default profile without a Doppel receipt.
    var inAppBrowserRuntimeKind = "none"
    var inAppBrowserRuntimeInstanceID = ""
    var inAppBrowserRuntimeInstanceName = ""
    var browserHosts: [BrowserHost] = []
    /// Display names of instances that have a browser extension host installed,
    /// and so can actually be handed the registration.
    var instancesWithBrowserHost: Set<String> = []

    var chronicleIsFresh: Bool {
        chronicle == .running && chronicleFrameAge.map { (0...120).contains($0) } == true
    }

    var inAppBrowserAssignmentConflicted: Bool {
        guard !inAppBrowserInstanceName.isEmpty, inAppBrowserRuntimeKind != "none" else {
            return false
        }
        return inAppBrowserRuntimeKind != "managed" ||
            inAppBrowserRuntimeInstanceID != inAppBrowserInstanceID
    }

    var inAppBrowserRunningOutsideDoppel: Bool {
        inAppBrowserRuntimeKind != "none" &&
            (inAppBrowserInstanceName.isEmpty || inAppBrowserAssignmentState == "untracked")
    }

    // The owner as reported for every browser, when they agree. They disagree
    // only if something rewrote one registration and not the others, which is
    // worth showing rather than hiding behind whichever came first.
    var sharedBrowserOwner: String? {
        guard let first = browserHosts.first else { return nil }
        return browserHosts.allSatisfy { $0.owner == first.owner } ? first.owner : nil
    }

    /// The instances named in the owner column. Several instances can share one
    /// CODEX_HOME, in which case the column names all of them, so this is a set
    /// rather than a single name to compare against.
    var browserOwnerNames: Set<String> {
        guard let owner = sharedBrowserOwner else { return [] }
        return Set(owner.components(separatedBy: ", ").filter { !$0.isEmpty })
    }

    static func parse(_ output: String) -> NativeToolsStatus? {
        var status = NativeToolsStatus()
        var recognized = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let kind = fields.first else { continue }
            switch kind {
            case "computer-use" where fields.count >= 2:
                status.computerUse = ComputerUseState(rawValue: fields[1]) ?? .unknown
                recognized = true
            case "chronicle" where fields.count >= 5:
                status.chronicle = ChronicleState(rawValue: fields[1]) ?? .unknown
                status.chronicleHost = fields[2]
                status.chronicleAppPath = fields[3]
                if let age = Int(fields[4]), age >= 0 { status.chronicleFrameAge = age }
                recognized = true
            case "rollbacks" where fields.count >= 2:
                status.discoverableRollbacks = max(0, Int(fields[1]) ?? 0)
                recognized = true
            case "in-app-browser" where fields.count >= 2:
                switch fields[1] {
                case "assigned" where fields.count >= 6:
                    status.inAppBrowserInstanceID = fields[2]
                    status.inAppBrowserInstanceName = fields[3]
                    status.inAppBrowserAssignmentState = fields[4]
                    status.inAppBrowserRunning = fields[4] == "running" || fields[4] == "untracked"
                    status.inAppBrowserVendorValid = fields[5] == "valid"
                    if fields.count >= 9 {
                        status.inAppBrowserRuntimeKind = fields[6]
                        status.inAppBrowserRuntimeInstanceID = fields[7]
                        status.inAppBrowserRuntimeInstanceName = fields[8]
                    }
                case "unavailable-in-instances":
                    status.inAppBrowserUnavailable = true
                case "unassigned" where fields.count >= 5:
                    status.inAppBrowserRuntimeKind = fields[2]
                    status.inAppBrowserRuntimeInstanceID = fields[3]
                    status.inAppBrowserRuntimeInstanceName = fields[4]
                default:
                    break // "unassigned" is recognized but carries no profile.
                }
                recognized = true
            case "instance" where fields.count >= 6:
                // Only the browser-host flag is taken from these rows; the menu
                // has everything else about an instance from `list`.
                if fields[5] == "yes" { status.instancesWithBrowserHost.insert(fields[2]) }
                recognized = true
            case "browser-host" where fields.count >= 5:
                status.browserHosts.append(BrowserHost(
                    browser: fields[1],
                    owner: fields[2],
                    codexHome: fields[3],
                    manifestPath: fields[4]))
                recognized = true
            default:
                // `instance` rows deliberately carry exact paths for command-
                // line diagnostics. The menu already has them from `list`.
                // Anything else is a row added by a newer CLI than this build.
                continue
            }
        }
        return recognized ? status : nil
    }
}
