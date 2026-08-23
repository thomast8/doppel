import Foundation

struct LiveSwitchInstanceStatus: Equatable {
    enum Phase: Equatable {
        case disabled
        case waitingForApp
        case waitingForWindow
        case watching(NativeRoute)
        case switching(NativeRoute)
        case failed(LiveSwitchFailure)
    }

    let phase: Phase

    var label: String {
        switch phase {
        case .disabled:
            "Off"
        case .waitingForApp:
            "Waiting for Codex to run"
        case .waitingForWindow:
            "Waiting for this Codex window"
        case .watching(let route):
            "Watching \(route.label)"
        case .switching(let route):
            "Switching to \(route.label)…"
        case .failed(let failure):
            failure.userMessage
        }
    }

    var systemImage: String {
        switch phase {
        case .disabled:
            "circle"
        case .waitingForApp, .waitingForWindow:
            "circle.dotted"
        case .watching:
            "eye.circle.fill"
        case .switching:
            "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}
