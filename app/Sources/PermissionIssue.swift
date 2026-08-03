import Foundation

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

    var canRequest: Bool { permission != "permission-check" }

    var systemImage: String {
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
        case "not-requested": return "Not requested"
        case "missing": return "Missing"
        case "denied": return "Denied"
        case "restricted": return "Restricted"
        case "outdated": return "Rebuild needed"
        case "error": return "Check failed"
        default: return status
        }
    }

    static func parse(_ output: String) -> [PermissionIssue] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[3] != "granted" else { return nil }
            return PermissionIssue(
                instanceID: String(fields[0]),
                instanceName: String(fields[1]),
                permission: String(fields[2]),
                status: String(fields[3]))
        }
    }
}
