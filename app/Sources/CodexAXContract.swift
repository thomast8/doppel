import Foundation

struct CodexAXContract {
    struct Match: Equatable {
        let route: NativeRoute
        let composerID: Int
        let composerText: String
        let stopButtonID: Int?
        let sendButtonID: Int?
        let safetyFailure: LiveSwitchFailure?

        var turnIsActive: Bool { stopButtonID != nil }
    }

    func resolve(_ elements: [CodexAXElementDescriptor]) -> Match? {
        guard let composer = uniqueComposer(in: elements),
              let route = uniqueRoute(in: elements)
        else { return nil }

        let stopButtons = elements.filter(isStopButton)
        let sendButtons = elements.filter(isSendButton)
        guard stopButtons.count <= 1, sendButtons.count <= 1 else { return nil }
        let turnIsActive = stopButtons.count == 1
        guard turnIsActive || sendButtons.count == 1 else { return nil }

        let safetyFailure: LiveSwitchFailure?
        if hasBlockingApproval(in: elements) {
            safetyFailure = .approvalPresent
        } else if hasAttachment(in: elements) {
            safetyFailure = .attachmentPresent
        } else if !composer.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            safetyFailure = .draftPresent
        } else {
            safetyFailure = nil
        }
        return Match(
            route: route,
            composerID: composer.id,
            composerText: composer.value,
            stopButtonID: stopButtons.first?.id,
            sendButtonID: sendButtons.first?.id,
            safetyFailure: safetyFailure)
    }

    private func uniqueComposer(
        in elements: [CodexAXElementDescriptor]
    ) -> CodexAXElementDescriptor? {
        let inputs = elements.filter {
            $0.enabled && ($0.role == "AXTextArea" || $0.role == "AXTextField")
        }
        let preferred = inputs.filter {
            containsAny($0.semanticText, ["prompt", "message", "do anything", "ask anything"])
        }
        if preferred.count == 1 { return preferred[0] }
        return inputs.count == 1 ? inputs[0] : nil
    }

    private func uniqueRoute(in elements: [CodexAXElementDescriptor]) -> NativeRoute? {
        let candidates = elements.compactMap { info -> (Int, NativeRoute)? in
            guard info.enabled, isButtonRole(info.role),
                  !isStopButton(info), !isSendButton(info),
                  let label = routeLabel(from: info), let route = NativeRoute(label: label)
            else { return nil }
            let semantic = info.semanticText
            var score = 0
            if containsAny(semantic, ["model", "reasoning", "effort"]) { score += 100 }
            if hasEffortSuffix(route.label) { score += 50 }
            if info.role == "AXPopUpButton" || info.role == "AXMenuButton" { score += 20 }
            if containsAny(semantic, ["microphone", "voice", "attach", "upload", "tool", "permission"]) {
                score -= 200
            }
            return score > 0 ? (score, route) : nil
        }
        guard let bestScore = candidates.map(\.0).max() else { return nil }
        let best = candidates.filter { $0.0 == bestScore }.map(\.1)
        return best.count == 1 ? best[0] : nil
    }

    private func routeLabel(from info: CodexAXElementDescriptor) -> String? {
        let candidates = [info.value, info.title, info.childLabels.joined(separator: " "),
                          info.description]
        return candidates.first { candidate in
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty,
                  normalized.rangeOfCharacter(from: .letters) != nil
            else { return false }
            return !["model", "choose model", "select model", "reasoning", "reasoning effort",
                     "model and reasoning"].contains(normalized)
        }
    }

    private func isStopButton(_ info: CodexAXElementDescriptor) -> Bool {
        guard info.enabled, isButtonRole(info.role) else { return false }
        return info.labels.contains { label in
            let normalized = normalizedLabel(label)
            return normalized == "stop" || normalized == "stop generating" ||
                normalized == "stop response" || normalized == "stop codex"
        }
    }

    private func isSendButton(_ info: CodexAXElementDescriptor) -> Bool {
        guard info.enabled, isButtonRole(info.role) else { return false }
        return info.labels.contains { label in
            let normalized = normalizedLabel(label)
            return normalized == "send" || normalized == "send message" ||
                normalized == "submit" || normalized == "submit message"
        }
    }

    private func hasBlockingApproval(in elements: [CodexAXElementDescriptor]) -> Bool {
        if elements.contains(where: {
            $0.role == "AXSheet" || $0.role == "AXDialog" || $0.subrole == "AXDialog"
        }) { return true }
        return elements.filter { $0.enabled && isButtonRole($0.role) }.contains { info in
            info.labels.contains { label in
                let normalized = normalizedLabel(label)
                return ["approve", "approve once", "allow", "allow once", "deny", "reject"].contains(normalized)
            }
        }
    }

    private func hasAttachment(in elements: [CodexAXElementDescriptor]) -> Bool {
        elements.filter { $0.enabled && isButtonRole($0.role) }.contains { info in
            info.labels.contains { label in
                let normalized = normalizedLabel(label)
                let removal = normalized.contains("remove") || normalized.contains("delete")
                let words = normalized.split { !$0.isLetter }.map(String.init)
                let attachment = words.contains { word in
                    ["attachment", "file", "image", "document", "pdf"].contains(word)
                }
                return removal && attachment
            }
        }
    }

    private func isButtonRole(_ role: String) -> Bool {
        role == "AXButton" || role == "AXPopUpButton" || role == "AXMenuButton"
    }

    private func hasEffortSuffix(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter }
        guard let last = words.last else { return false }
        return ["light", "low", "medium", "high", "max", "ultra"].contains(String(last))
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func normalizedLabel(_ label: String) -> String {
        label.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }
}
