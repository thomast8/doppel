import AppKit
import ApplicationServices
import Foundation

@MainActor
final class CodexAXAdapter {
    enum Inspection {
        case snapshot(CodexAXSnapshot)
        case unavailable(LiveSwitchFailure)
    }

    private let contract = CodexAXContract()
    private static let messagingTimeout: Float = 0.25
    private static let inspectionBudget: TimeInterval = 1.5

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func inspect(_ target: LiveSwitchTarget) -> Inspection {
        guard Self.isTrusted else { return .unavailable(.accessibilityRequired) }
        guard target.state == .running, let pid = target.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == target.bundleID,
              pathsMatch(running.bundleURL?.path, target.appPath)
        else { return .unavailable(.processChanged) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .unavailable(.notFrontmost)
        }

        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, Self.messagingTimeout) == .success else {
            return .unavailable(.unsupportedUI)
        }
        guard let window = elementAttribute(kAXFocusedWindowAttribute as CFString, from: application) else {
            return .unavailable(.unsupportedUI)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Self.inspectionBudget
        let elements = interactiveElements(in: window, deadline: deadline)
        guard let match = contract.resolve(elements.map(\.descriptor)),
              let composer = elements.first(where: { $0.descriptor.id == match.composerID })?.element
        else { return .unavailable(.unsupportedUI) }
        let stopButton = match.stopButtonID.flatMap { id in
            elements.first(where: { $0.descriptor.id == id })?.element
        }
        let sendButton = match.sendButtonID.flatMap { id in
            elements.first(where: { $0.descriptor.id == id })?.element
        }

        return .snapshot(CodexAXSnapshot(
            route: match.route,
            turnIsActive: match.turnIsActive,
            windowToken: "\(pid):\(CFHash(window))",
            safetyFailure: match.safetyFailure,
            composer: composer,
            composerText: match.composerText,
            stopButton: stopButton,
            sendButton: sendButton))
    }

    func pressStop(in snapshot: CodexAXSnapshot) -> LiveSwitchFailure? {
        guard snapshot.turnIsActive, snapshot.safetyFailure == nil,
              let stopButton = snapshot.stopButton,
              AXUIElementPerformAction(stopButton, kAXPressAction as CFString) == .success
        else { return .interruptFailed }
        return nil
    }

    func submitContinuation(
        _ message: String, in snapshot: CodexAXSnapshot
    ) -> LiveSwitchFailure? {
        guard !snapshot.turnIsActive,
              snapshot.safetyFailure == nil,
              snapshot.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sendButton = snapshot.sendButton
        else { return .composerWriteFailed }

        var valueIsSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            snapshot.composer, kAXValueAttribute as CFString, &valueIsSettable) == .success,
              valueIsSettable.boolValue,
              AXUIElementSetAttributeValue(
                snapshot.composer, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        else { return .composerWriteFailed }
        guard AXUIElementSetAttributeValue(
            snapshot.composer, kAXValueAttribute as CFString, message as CFString) == .success,
              stringAttribute(kAXValueAttribute as CFString, from: snapshot.composer) == message
        else {
            clearContinuationIfExact(message, in: snapshot)
            return .composerWriteFailed
        }

        guard AXUIElementPerformAction(sendButton, kAXPressAction as CFString) == .success else {
            clearContinuationIfExact(message, in: snapshot)
            return .sendFailed
        }
        return nil
    }

    func clearContinuationIfExact(_ message: String, in snapshot: CodexAXSnapshot) {
        guard stringAttribute(kAXValueAttribute as CFString, from: snapshot.composer) == message else {
            return
        }
        AXUIElementSetAttributeValue(
            snapshot.composer, kAXValueAttribute as CFString, "" as CFString)
    }

    private struct ElementInfo {
        let element: AXUIElement
        let descriptor: CodexAXElementDescriptor
    }

    private func interactiveElements(
        in root: AXUIElement, deadline: TimeInterval
    ) -> [ElementInfo] {
        var result: [ElementInfo] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen: Set<CFHashCode> = []
        var index = 0
        while index < queue.count, index < 2_500, result.count < 1_200 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            let (element, depth) = queue[index]
            index += 1
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else { continue }
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if isRelevantRole(role) {
                result.append(ElementInfo(
                    element: element,
                    descriptor: CodexAXElementDescriptor(
                        id: result.count,
                        role: role,
                        subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element) ?? "",
                        title: stringAttribute(kAXTitleAttribute as CFString, from: element) ?? "",
                        description: stringAttribute(
                            kAXDescriptionAttribute as CFString, from: element) ?? "",
                        help: stringAttribute(kAXHelpAttribute as CFString, from: element) ?? "",
                        identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element) ?? "",
                        placeholder: stringAttribute(
                            "AXPlaceholderValue" as CFString, from: element) ?? "",
                        value: stringAttribute(kAXValueAttribute as CFString, from: element) ?? "",
                        childLabels: descendantLabels(
                            of: element, remainingDepth: 2, deadline: deadline),
                        enabled: boolAttribute(
                            kAXEnabledAttribute as CFString, from: element) ?? true)))
            }
            guard depth < 24 else { continue }
            queue.append(contentsOf: childElements(of: element).map { ($0, depth + 1) })
        }
        return result
    }

    private func descendantLabels(
        of element: AXUIElement, remainingDepth: Int, deadline: TimeInterval
    ) -> [String] {
        guard remainingDepth > 0,
              ProcessInfo.processInfo.systemUptime < deadline
        else { return [] }
        var labels: [String] = []
        for child in childElements(of: element).prefix(12) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            let role = stringAttribute(kAXRoleAttribute as CFString, from: child) ?? ""
            if role == kAXStaticTextRole {
                if let value = stringAttribute(kAXValueAttribute as CFString, from: child), !value.isEmpty {
                    labels.append(value)
                } else if let title = stringAttribute(kAXTitleAttribute as CFString, from: child), !title.isEmpty {
                    labels.append(title)
                }
            } else {
                labels.append(contentsOf: descendantLabels(
                    of: child, remainingDepth: remainingDepth - 1, deadline: deadline))
            }
            if labels.count >= 8 { break }
        }
        return labels
    }

    private func isRelevantRole(_ role: String) -> Bool {
        isButtonRole(role) || role == kAXTextAreaRole || role == kAXTextFieldRole ||
            role == "AXSheet" || role == "AXDialog"
    }

    private func isButtonRole(_ role: String) -> Bool {
        role == kAXButtonRole || role == kAXPopUpButtonRole || role == "AXMenuButton"
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func boolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber
        else { return nil }
        return number.boolValue
    }

    private func pathsMatch(_ actual: String?, _ expected: String) -> Bool {
        guard let actual else { return false }
        return URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL ==
            URL(fileURLWithPath: expected).resolvingSymlinksInPath().standardizedFileURL
    }
}
