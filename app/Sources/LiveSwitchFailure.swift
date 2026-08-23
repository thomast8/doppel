import Foundation

enum LiveSwitchFailure: String, Error, Equatable {
    case accessibilityRequired
    case targetInvalid
    case processChanged
    case unsupportedUI
    case notFrontmost
    case draftPresent
    case attachmentPresent
    case approvalPresent
    case routeChanged
    case focusChanged
    case interruptFailed
    case interruptTimedOut
    case composerWriteFailed
    case sendFailed
    case startTimedOut

    var userMessage: String {
        switch self {
        case .accessibilityRequired:
            "Accessibility permission required"
        case .targetInvalid:
            "Managed target could not be verified"
        case .processChanged:
            "Codex restarted during the switch"
        case .unsupportedUI:
            "Unsupported Codex controls"
        case .notFrontmost:
            "Waiting for this Codex window"
        case .draftPresent:
            "Draft present; switch not applied"
        case .attachmentPresent:
            "Attachment present; switch not applied"
        case .approvalPresent:
            "Approval open; switch not applied"
        case .routeChanged:
            "Model selection changed again"
        case .focusChanged:
            "Codex window changed during the switch"
        case .interruptFailed:
            "Codex could not be stopped"
        case .interruptTimedOut:
            "Codex did not stop in time"
        case .composerWriteFailed:
            "Continuation could not be inserted"
        case .sendFailed:
            "Continuation could not be sent"
        case .startTimedOut:
            "The continued turn did not start"
        }
    }
}
