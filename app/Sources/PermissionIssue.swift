import Foundation

enum PermissionAction: Equatable {
    case requestNative
    case openSettings
    case unavailable
}

struct PermissionIssue: Hashable, Identifiable {
    let instanceID: String
    let instanceName: String
    let permission: String
    let status: String

    var id: String { "\(instanceID):\(permission)" }

    var label: String {
        switch permission {
        case "accessibility": return "Accessibility"
        case "screen-recording": return "Screen & System Audio Recording"
        case "microphone": return "Microphone"
        case "camera": return "Camera"
        case "notifications": return "Notifications"
        case "permission-check": return "Permission checker update"
        default: return permission
        }
    }

    /// Only an explicit denial is actionable enough to turn the menu-bar icon
    /// into a warning. Camera and microphone are optional until the user tries
    /// those features, while Accessibility and Screen Recording return only a
    /// boolean and can be false even when System Settings still shows the app
    /// enabled. Calling either of those states "missing" was misleading.
    var needsAttention: Bool {
        if permission == "permission-check" { return status == "outdated" || status == "error" }
        return status == "denied" || status == "restricted"
    }

    var systemImage: String {
        if status == "granted" { return "checkmark.circle.fill" }
        if status == "not-requested" { return "circle.dotted" }
        if status == "missing" || status == "unconfirmed" { return "questionmark.circle" }
        switch permission {
        case "microphone": return "mic.slash.fill"
        case "camera": return "video.slash.fill"
        case "screen-recording": return "rectangle.on.rectangle.slash"
        case "accessibility": return "accessibility"
        case "notifications": return "bell.slash.fill"
        case "permission-check": return "arrow.triangle.2.circlepath.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var statusLabel: String {
        switch status {
        case "granted": return "Granted"
        case "not-requested": return "Not requested"
        case "missing", "unconfirmed": return "Check in Settings"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "outdated": return "Rebuild needed"
        case "error": return "Check failed"
        default: return status
        }
    }

    /// Accessibility and Screen Recording never confirm a completed request:
    /// their APIs stay boolean, so a row can still read "missing" after the
    /// native flow ran. Conclusive statuses (microphone, camera, notifications)
    /// either prompt or move to granted/denied, so repeating their native
    /// request is always meaningful and must not fall back to Settings.
    var nativeRequestCanStayInconclusive: Bool {
        status == "missing" || status == "unconfirmed"
    }

    /// An app that has never requested microphone/camera access does not exist
    /// in that System Settings list yet. Those and the boolean-only checks must
    /// first run Apple's native request as the managed app. Explicit denials
    /// can only be changed in Settings; granted rows remain useful shortcuts.
    var action: PermissionAction {
        guard permission != "permission-check", settingsURL != nil else { return .unavailable }
        switch status {
        case "not-requested", "missing", "unconfirmed": return .requestNative
        default: return .openSettings
        }
    }

    static func parseStatuses(_ output: String) -> [PermissionIssue] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            return PermissionIssue(
                instanceID: String(fields[0]),
                instanceName: String(fields[1]),
                permission: String(fields[2]),
                status: String(fields[3]))
        }
    }

    static func parse(_ output: String) -> [PermissionIssue] {
        parseStatuses(output).filter(\.needsAttention)
    }

    var settingsURL: URL? {
        if permission == "notifications" {
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
        let pane: String
        switch permission {
        case "accessibility": pane = "Privacy_Accessibility"
        case "screen-recording": pane = "Privacy_ScreenCapture"
        case "microphone": pane = "Privacy_Microphone"
        case "camera": pane = "Privacy_Camera"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}
