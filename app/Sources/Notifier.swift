import Foundation
import UserNotifications

/// What Doppel tells the user about long-running work, as plain text, so the
/// panel and the notifications say the same thing and the wording is testable.
enum StatusMessages {
    /// The CLI reports no steps while it works, so this names the phase the
    /// app started rather than pretending to know how far along it is.
    static func progress(for update: ChatGPTUpdate) -> String {
        switch update.state {
        case .available: return "Downloading and verifying ChatGPT \(update.targetVersion)…"
        case .ready: return "Installing ChatGPT \(update.targetVersion) and rebuilding every instance…"
        case .staleInstances:
            return update.staleInstanceCount == 1
                ? "Rebuilding 1 outdated instance…"
                : "Rebuilding \(update.staleInstanceCount) outdated instances…"
        }
    }

    static func offer(_ update: ChatGPTUpdate) -> (title: String, body: String) {
        let action: String
        switch update.state {
        case .available: action = "Download it"
        case .ready: action = "Restart and update"
        case .staleInstances: action = "Rebuild them"
        }
        return (MenuContent.updateHeadline(update), "\(action) from the Doppel menu bar icon.")
    }

    /// A reconcile installs nothing, so saying an update was installed would be
    /// a claim the run never made.
    static func completion(_ update: ChatGPTUpdate, output: String,
                           signingReady: Bool) -> (title: String, body: String) {
        let fields = InstanceStore.resultFields(output)
        let outcome = fields.first ?? "updated"
        let verified = fields.count > 3 ? "\(fields[3]) instances" : "all instances"
        let reopened = fields.count > 4 ? fields[4] : "the ones that were running"
        let signingNote = signingReady ? "" :
            " This Mac uses ad-hoc signing, so macOS may have forgotten their permissions. Set up secure signing in Settings before the next update."
        switch outcome {
        case "reconciled":
            return ("Instances rebuilt",
                    "Doppel rebuilt \(verified) from ChatGPT \(update.targetVersion) and reopened \(reopened).\(signingNote)")
        case "current":
            return ("Nothing to rebuild",
                    "No instance needed rebuilding for ChatGPT \(update.targetVersion), so nothing was closed.")
        default:
            return ("ChatGPT \(update.targetVersion) installed",
                    "Doppel verified \(verified) and reopened \(reopened).\(signingNote)")
        }
    }
}

/// Posts macOS notifications for work that finishes or fails while the panel
/// is closed. Permission is asked the first time there is something to say.
@MainActor
enum Notifier {
    private static let presenter = ForegroundPresenter()

    static func post(_ title: String, _ body: String) {
        // The test runner and the offscreen renderer are not app bundles, and
        // the notification center refuses to exist outside one.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Without a delegate, macOS drops notifications while the posting app is
/// active, which a menu bar app often is right after the user clicked it.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// One step reported by the CLI or engine while it works. They print these to
/// stderr only when the app sets DOPPEL_PROGRESS=1.
struct CLIProgress: Equatable {
    let fraction: Double
    let label: String

    static let prefix = "doppel-progress\t"

    static func parse(_ line: String) -> CLIProgress? {
        guard line.hasPrefix(prefix) else { return nil }
        let fields = line.dropFirst(prefix.count).split(separator: "\t", maxSplits: 1)
        guard fields.count == 2, let percent = Int(fields[0]) else { return nil }
        return CLIProgress(fraction: Double(min(max(percent, 0), 100)) / 100, label: String(fields[1]))
    }

    /// stderr is also the failure message, which must not read as a list of
    /// the steps that went well before it.
    static func withoutProgress(_ stderr: String) -> String {
        stderr.split(separator: "\n").filter { !$0.hasPrefix(prefix) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
