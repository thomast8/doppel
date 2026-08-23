import ApplicationServices
import Foundation

struct CodexAXSnapshot {
    let route: NativeRoute
    let turnIsActive: Bool
    let windowToken: String
    let safetyFailure: LiveSwitchFailure?
    let composer: AXUIElement
    let composerText: String
    let stopButton: AXUIElement?
    let sendButton: AXUIElement?
}
