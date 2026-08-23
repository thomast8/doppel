import XCTest
@testable import DoppelMenuBar

final class LiveSwitchTests: XCTestCase {
    func testTargetContractParsing() throws {
        let fingerprint = String(repeating: "a", count: 64)
        let running = try XCTUnwrap(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tclone\tcom.example.work\t/Apps/Work.app\t/Users/me/.codex-work\trunning\t123\t\(fingerprint)\t7000\n"))
        XCTAssertEqual(running.instanceID, "work")
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.processIdentifier, 123)
        XCTAssertEqual(running.processFingerprint, fingerprint)
        XCTAssertEqual(running.build, 7000)

        let stopped = try XCTUnwrap(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tvendor\tcom.openai.codex\t/Applications/ChatGPT.app\t/Users/me/.codex-work\tstopped\t\t\t7001\n"))
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.processIdentifier)

        let missing = try XCTUnwrap(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tclone\tcom.example.work\t/Apps/Work.app\t/Users/me/.codex-work\tmissing\t\t\t\n"))
        XCTAssertEqual(missing.state, .missing)
        XCTAssertNil(missing.build)
    }

    func testTargetContractFailsClosed() {
        let fingerprint = String(repeating: "a", count: 64)
        XCTAssertNil(LiveSwitchTarget.parse(
            "unknown\twork\tclone\tcom.example.work\t/Apps/Work.app\t/Users/me/.codex\tstopped\t\t\t7000"))
        XCTAssertNil(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tclone\tcom.example.work\t/Apps/Work.app\t/Users/me/.codex\trunning\t123\tshort\t7000"))
        XCTAssertNil(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tclone\tcom.example.work\trelative.app\t/Users/me/.codex\tstopped\t\t\t7000"))
        XCTAssertNil(LiveSwitchTarget.parse(
            "live-switch-target-v1\twork\tclone\tcom.example.work\t/Apps/Work.app\t/Users/me/.codex\tstopped\t123\t\(fingerprint)\t7000"))
    }

    func testActiveRouteChangeInterruptsAndContinuesExactlyOnce() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        var machine = LiveSwitchStateMachine()

        XCTAssertEqual(machine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1.20), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1.25), .pressStop(high))
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 2), .none)
        XCTAssertEqual(machine.observe(observation(high, active: false), at: 2.1), .submitContinuation(high))
        XCTAssertEqual(machine.observe(observation(high, active: false), at: 2.2), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 2.3), .completed(high))
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 2.4), .none)
    }

    func testIdleAndNaturalCompletionNeverCreateAContinuation() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        var idleMachine = LiveSwitchStateMachine()
        XCTAssertEqual(idleMachine.observe(observation(medium, active: false), at: 0), .none)
        XCTAssertEqual(idleMachine.observe(observation(high, active: false), at: 1), .none)

        var racingMachine = LiveSwitchStateMachine()
        XCTAssertEqual(racingMachine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(racingMachine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(
            racingMachine.observe(observation(high, active: false), at: 1.1),
            .cancelled(high))
    }

    func testRapidPickerChangesCoalesceToLatestRoute() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        let ultra = try XCTUnwrap(NativeRoute(label: "5.6 Sol Ultra"))
        var machine = LiveSwitchStateMachine()
        XCTAssertEqual(machine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(machine.observe(observation(ultra, active: true), at: 1.1), .none)
        XCTAssertEqual(machine.observe(observation(ultra, active: true), at: 1.34), .none)
        XCTAssertEqual(machine.observe(observation(ultra, active: true), at: 1.35), .pressStop(ultra))
    }

    func testUnsafeOrChangedContextFailsClosed() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        var draftMachine = LiveSwitchStateMachine()
        XCTAssertEqual(draftMachine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(
            draftMachine.observe(
                observation(high, active: true, safetyFailure: .draftPresent), at: 1),
            .failed(.draftPresent, high))
        XCTAssertEqual(draftMachine.observe(observation(high, active: true), at: 2), .none)

        var focusMachine = LiveSwitchStateMachine()
        XCTAssertEqual(focusMachine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(focusMachine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(focusMachine.observe(observation(high, active: true), at: 1.3), .pressStop(high))
        XCTAssertEqual(
            focusMachine.observe(observation(high, active: true, window: "other"), at: 2),
            .failed(.focusChanged, high))
    }

    func testTimeoutsFailWithoutRetrying() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        var interruptMachine = LiveSwitchStateMachine(
            debounce: 0.25, interruptTimeout: 1, startTimeout: 1)
        XCTAssertEqual(interruptMachine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(interruptMachine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(interruptMachine.observe(observation(high, active: true), at: 1.25), .pressStop(high))
        XCTAssertEqual(
            interruptMachine.observe(observation(high, active: true), at: 2.25),
            .failed(.interruptTimedOut, high))
        XCTAssertEqual(interruptMachine.observe(observation(high, active: true), at: 3), .none)

        var startMachine = LiveSwitchStateMachine(
            debounce: 0.25, interruptTimeout: 1, startTimeout: 1)
        XCTAssertEqual(startMachine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(startMachine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(startMachine.observe(observation(high, active: true), at: 1.25), .pressStop(high))
        XCTAssertEqual(startMachine.observe(observation(high, active: false), at: 1.3), .submitContinuation(high))
        XCTAssertEqual(
            startMachine.observe(observation(high, active: false), at: 2.3),
            .failed(.startTimedOut, high))
    }

    func testMissingAXControlsRetainBoundedTimeouts() throws {
        let medium = try XCTUnwrap(NativeRoute(label: "5.6 Sol Medium"))
        let high = try XCTUnwrap(NativeRoute(label: "5.6 Sol High"))
        var machine = LiveSwitchStateMachine(
            debounce: 0.25, interruptTimeout: 1, startTimeout: 1)
        XCTAssertEqual(machine.observe(observation(medium, active: true), at: 0), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1), .none)
        XCTAssertEqual(machine.observe(observation(high, active: true), at: 1.25), .pressStop(high))
        XCTAssertEqual(machine.waitWithoutObservation(at: 2.24), .none)
        XCTAssertEqual(
            machine.waitWithoutObservation(at: 2.25),
            .failed(.interruptTimedOut, high))
    }

    func testAXContractRecognizesIdleAndRunningCodexControls() throws {
        let contract = CodexAXContract()
        let idle = try XCTUnwrap(contract.resolve([
            element(1, role: "AXTextArea", placeholder: "Do anything"),
            element(2, role: "AXButton", title: "5.6 Sol High"),
            element(3, role: "AXButton", description: "Send message"),
            element(4, role: "AXButton", description: "Microphone", value: "High"),
        ]))
        XCTAssertEqual(idle.route.label, "5.6 Sol High")
        XCTAssertFalse(idle.turnIsActive)
        XCTAssertEqual(idle.sendButtonID, 3)
        XCTAssertNil(idle.safetyFailure)

        let running = try XCTUnwrap(contract.resolve([
            element(1, role: "AXTextArea", description: "Message composer"),
            element(2, role: "AXPopUpButton", description: "Model and reasoning",
                    value: "5.6 Terra Ultra"),
            element(3, role: "AXButton", description: "Stop generating"),
        ]))
        XCTAssertEqual(running.route.label, "5.6 Terra Ultra")
        XCTAssertTrue(running.turnIsActive)
        XCTAssertEqual(running.stopButtonID, 3)
    }

    func testAXContractRejectsAmbiguousOrIncompleteTrees() {
        let contract = CodexAXContract()
        XCTAssertNil(contract.resolve([
            element(1, role: "AXTextArea", placeholder: "Do anything"),
            element(2, role: "AXButton", title: "5.6 Sol High"),
            element(3, role: "AXButton", title: "5.6 Terra High"),
            element(4, role: "AXButton", description: "Send"),
        ]))
        XCTAssertNil(contract.resolve([
            element(1, role: "AXTextArea", placeholder: "Do anything"),
            element(2, role: "AXButton", title: "5.6 Sol High"),
        ]))
        XCTAssertNil(contract.resolve([
            element(1, role: "AXTextArea", placeholder: "Message"),
            element(2, role: "AXTextArea", description: "Prompt"),
            element(3, role: "AXButton", title: "5.6 Sol High"),
            element(4, role: "AXButton", description: "Send"),
        ]))
    }

    func testAXContractFailsClosedForDraftAttachmentAndApproval() throws {
        let contract = CodexAXContract()
        let base = [
            element(1, role: "AXTextArea", placeholder: "Do anything"),
            element(2, role: "AXButton", title: "5.6 Sol High"),
            element(3, role: "AXButton", description: "Stop"),
            // This composer policy control is not an active approval.
            element(4, role: "AXButton", title: "Approve for me"),
        ]
        XCTAssertNil(try XCTUnwrap(contract.resolve(base)).safetyFailure)

        var draft = base
        draft[0] = element(1, role: "AXTextArea", placeholder: "Do anything", value: "unsent")
        XCTAssertEqual(try XCTUnwrap(contract.resolve(draft)).safetyFailure, .draftPresent)

        var attachment = base
        attachment.append(element(5, role: "AXButton", description: "Remove attachment"))
        XCTAssertEqual(
            try XCTUnwrap(contract.resolve(attachment)).safetyFailure,
            .attachmentPresent)

        var image = base
        image.append(element(5, role: "AXButton", description: "Remove image"))
        XCTAssertEqual(
            try XCTUnwrap(contract.resolve(image)).safetyFailure,
            .attachmentPresent)

        var approval = base
        approval.append(element(5, role: "AXButton", title: "Approve once"))
        XCTAssertEqual(try XCTUnwrap(contract.resolve(approval)).safetyFailure, .approvalPresent)
    }

    private func observation(
        _ route: NativeRoute,
        active: Bool,
        window: String = "window-1",
        safetyFailure: LiveSwitchFailure? = nil
    ) -> LiveSwitchStateMachine.Observation {
        LiveSwitchStateMachine.Observation(
            route: route, turnIsActive: active,
            windowToken: window, safetyFailure: safetyFailure)
    }

    private func element(
        _ id: Int,
        role: String,
        subrole: String = "",
        title: String = "",
        description: String = "",
        help: String = "",
        identifier: String = "",
        placeholder: String = "",
        value: String = "",
        childLabels: [String] = [],
        enabled: Bool = true
    ) -> CodexAXElementDescriptor {
        CodexAXElementDescriptor(
            id: id, role: role, subrole: subrole,
            title: title, description: description, help: help,
            identifier: identifier, placeholder: placeholder,
            value: value, childLabels: childLabels, enabled: enabled)
    }
}
