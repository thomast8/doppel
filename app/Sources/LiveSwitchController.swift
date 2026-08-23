import AppKit
import Foundation
import OSLog

@MainActor
final class LiveSwitchController: ObservableObject {
    static let continuationMessage = """
        [Doppel live switch] Continue after the model/reasoning switch. Inspect the current state and resume only unfinished work. Preserve completed changes and verify any interrupted command before proceeding.
        """

    @Published private(set) var enabledInstanceIDs: Set<String>
    @Published private(set) var statuses: [String: LiveSwitchInstanceStatus] = [:]

    private static let preferencesKey = "LiveModelReasoningSwitchInstanceIDs"
    private static let targetRefreshInterval: TimeInterval = 1
    private static let observationInterval: TimeInterval = 0.1

    private final class Watcher {
        var target: LiveSwitchTarget?
        var lastTargetRefresh: TimeInterval = 0
        var machine = LiveSwitchStateMachine()
        var lastSnapshot: CodexAXSnapshot?
    }

    private let defaults: UserDefaults
    private let adapter: CodexAXAdapter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.doppel.menubar",
        category: "LiveSwitch")
    private var cli: URL?
    private var instances: [String: Instance] = [:]
    private var watchers: [String: Watcher] = [:]
    private var targetResolutionsInFlight: Set<String> = []
    private var timer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        adapter = CodexAXAdapter()
        let stored = defaults.stringArray(forKey: Self.preferencesKey) ?? []
        enabledInstanceIDs = Set(stored)
    }

    deinit {
        timer?.invalidate()
    }

    func configure(cli: URL?, instances: [Instance]) {
        self.cli = cli
        self.instances = Dictionary(uniqueKeysWithValues: instances.map { ($0.id, $0) })
        let knownIDs = Set(self.instances.keys)
        let removedIDs = enabledInstanceIDs.subtracting(knownIDs)
        if !removedIDs.isEmpty {
            enabledInstanceIDs.subtract(removedIDs)
            persistEnabledInstances()
            for id in removedIDs {
                if let watcher = watchers[id] {
                    clearPendingContinuationIfNeeded(watcher)
                }
                watchers[id] = nil
                statuses[id] = nil
            }
        }
        for id in enabledInstanceIDs where watchers[id] == nil {
            watchers[id] = Watcher()
            statuses[id] = LiveSwitchInstanceStatus(phase: .waitingForApp)
        }
        startTimerIfNeeded()
        tick()
    }

    func isEnabled(for instance: Instance) -> Bool {
        enabledInstanceIDs.contains(instance.id)
    }

    func status(for instance: Instance) -> LiveSwitchInstanceStatus {
        statuses[instance.id] ?? LiveSwitchInstanceStatus(phase: .disabled)
    }

    func toggle(for instance: Instance) {
        setEnabled(!isEnabled(for: instance), for: instance)
    }

    func setEnabled(_ enabled: Bool, for instance: Instance) {
        if enabled {
            enabledInstanceIDs.insert(instance.id)
            watchers[instance.id] = watchers[instance.id] ?? Watcher()
            if !CodexAXAdapter.isTrusted {
                _ = CodexAXAdapter.requestTrust()
                statuses[instance.id] = LiveSwitchInstanceStatus(
                    phase: .failed(.accessibilityRequired))
            } else {
                statuses[instance.id] = LiveSwitchInstanceStatus(phase: .waitingForApp)
            }
            logger.info("Enabled live switching for \(instance.id, privacy: .public)")
        } else {
            enabledInstanceIDs.remove(instance.id)
            if let watcher = watchers[instance.id] {
                clearPendingContinuationIfNeeded(watcher)
            }
            watchers[instance.id] = nil
            targetResolutionsInFlight.remove(instance.id)
            statuses[instance.id] = LiveSwitchInstanceStatus(phase: .disabled)
            logger.info("Disabled live switching for \(instance.id, privacy: .public)")
        }
        persistEnabledInstances()
        startTimerIfNeeded()
        tick()
    }

    private func startTimerIfNeeded() {
        if enabledInstanceIDs.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.observationInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !enabledInstanceIDs.isEmpty else { return }
        guard CodexAXAdapter.isTrusted else {
            for id in enabledInstanceIDs {
                statuses[id] = LiveSwitchInstanceStatus(phase: .failed(.accessibilityRequired))
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        for id in enabledInstanceIDs {
            guard let instance = instances[id], let watcher = watchers[id] else { continue }
            if now - watcher.lastTargetRefresh >= Self.targetRefreshInterval {
                resolveTarget(for: instance, watcher: watcher, at: now)
            }
            observe(instance: instance, watcher: watcher, at: now)
        }
    }

    private func resolveTarget(for instance: Instance, watcher: Watcher, at now: TimeInterval) {
        guard !targetResolutionsInFlight.contains(instance.id), let cli else {
            if cli == nil {
                statuses[instance.id] = LiveSwitchInstanceStatus(phase: .failed(.targetInvalid))
            }
            return
        }
        targetResolutionsInFlight.insert(instance.id)
        watcher.lastTargetRefresh = now
        Task.detached { [weak self] in
            let result = InstanceStore.runProcess(
                cli: cli, arguments: ["live-switch", "target", instance.id])
            await MainActor.run { [weak self] in
                self?.acceptTargetResult(result, for: instance.id)
            }
        }
    }

    private func acceptTargetResult(_ result: ProcessResult, for instanceID: String) {
        targetResolutionsInFlight.remove(instanceID)
        guard enabledInstanceIDs.contains(instanceID), let watcher = watchers[instanceID] else { return }
        switch result {
        case .failure:
            clearPendingContinuationIfNeeded(watcher)
            watcher.target = nil
            watcher.machine.reset()
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .failed(.targetInvalid))
            logger.error("Target resolution failed for \(instanceID, privacy: .public)")
        case .success(let output):
            guard let target = LiveSwitchTarget.parse(output), target.instanceID == instanceID else {
                clearPendingContinuationIfNeeded(watcher)
                watcher.target = nil
                watcher.machine.reset()
                statuses[instanceID] = LiveSwitchInstanceStatus(phase: .failed(.targetInvalid))
                logger.error("Target contract was unreadable for \(instanceID, privacy: .public)")
                return
            }
            if let previous = watcher.target,
               previous.state == .running,
               target != previous,
               isSwitchInFlight(watcher.machine.state),
               let route = watcher.lastSnapshot?.route {
                let wasWaitingForStart = isWaitingForStart(watcher.machine.state)
                handle(
                    watcher.machine.fail(.processChanged, route: route),
                    instanceID: instanceID, watcher: watcher,
                    snapshot: watcher.lastSnapshot,
                    wasWaitingForStart: wasWaitingForStart)
            }
            if target.state != .running {
                clearPendingContinuationIfNeeded(watcher)
                watcher.machine.reset()
                watcher.lastSnapshot = nil
            }
            watcher.target = target
            if target.state != .running {
                statuses[instanceID] = LiveSwitchInstanceStatus(phase: .waitingForApp)
            }
        }
    }

    private func observe(instance: Instance, watcher: Watcher, at now: TimeInterval) {
        guard let target = watcher.target else { return }
        guard target.state == .running else {
            statuses[instance.id] = LiveSwitchInstanceStatus(phase: .waitingForApp)
            return
        }
        switch adapter.inspect(target) {
        case .unavailable(let failure):
            let wasWaitingForStart: Bool
            if case .waitingForStart = watcher.machine.state {
                wasWaitingForStart = true
            } else {
                wasWaitingForStart = false
            }
            if failure == .unsupportedUI, isWaitingForControlTransition(watcher.machine.state) {
                handle(
                    watcher.machine.waitWithoutObservation(at: now),
                    instanceID: instance.id, watcher: watcher,
                    snapshot: watcher.lastSnapshot, wasWaitingForStart: wasWaitingForStart)
            } else if isSwitchInFlight(watcher.machine.state), let route = watcher.lastSnapshot?.route {
                let effectiveFailure: LiveSwitchFailure = failure == .notFrontmost
                    ? .focusChanged : failure
                handle(
                    watcher.machine.fail(effectiveFailure, route: route),
                    instanceID: instance.id, watcher: watcher,
                    snapshot: watcher.lastSnapshot, wasWaitingForStart: wasWaitingForStart)
            } else if failure == .notFrontmost {
                statuses[instance.id] = LiveSwitchInstanceStatus(phase: .waitingForWindow)
            } else {
                statuses[instance.id] = LiveSwitchInstanceStatus(phase: .failed(failure))
            }

        case .snapshot(let snapshot):
            let wasWaitingForStart: Bool
            if case .waitingForStart = watcher.machine.state {
                wasWaitingForStart = true
            } else {
                wasWaitingForStart = false
            }
            watcher.lastSnapshot = snapshot
            let observation = LiveSwitchStateMachine.Observation(
                route: snapshot.route,
                turnIsActive: snapshot.turnIsActive,
                windowToken: snapshot.windowToken,
                safetyFailure: snapshot.safetyFailure)
            let action = watcher.machine.observe(observation, at: now)
            handle(
                action, instanceID: instance.id, watcher: watcher,
                snapshot: snapshot, wasWaitingForStart: wasWaitingForStart)
        }
    }

    private func handle(
        _ action: LiveSwitchStateMachine.Action,
        instanceID: String,
        watcher: Watcher,
        snapshot: CodexAXSnapshot?,
        wasWaitingForStart: Bool
    ) {
        switch action {
        case .none:
            publishMachineStatus(watcher.machine.state, for: instanceID, fallback: snapshot?.route)

        case .pressStop(let route):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .switching(route))
            logger.info("Interrupting \(instanceID, privacy: .public) for route \(route.label, privacy: .public)")
            let freshSnapshot: CodexAXSnapshot
            switch revalidatedSnapshot(
                for: watcher, expected: snapshot, route: route, turnIsActive: true
            ) {
            case .failure(let failure):
                handleFailure(failure, route: route, instanceID: instanceID,
                              watcher: watcher, snapshot: snapshot)
                return
            case .success(let verified):
                freshSnapshot = verified
                watcher.lastSnapshot = verified
            }
            if let failure = adapter.pressStop(in: freshSnapshot) {
                handleFailure(failure, route: route, instanceID: instanceID,
                              watcher: watcher, snapshot: freshSnapshot)
            }

        case .submitContinuation(let route):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .switching(route))
            let freshSnapshot: CodexAXSnapshot
            switch revalidatedSnapshot(
                for: watcher, expected: snapshot, route: route, turnIsActive: false
            ) {
            case .failure(let failure):
                handleFailure(failure, route: route, instanceID: instanceID,
                              watcher: watcher, snapshot: snapshot)
                return
            case .success(let verified):
                freshSnapshot = verified
                watcher.lastSnapshot = verified
            }
            if let failure = adapter.submitContinuation(Self.continuationMessage, in: freshSnapshot) {
                handleFailure(failure, route: route, instanceID: instanceID,
                              watcher: watcher, snapshot: freshSnapshot)
            } else {
                logger.info("Submitted continuation for \(instanceID, privacy: .public) at route \(route.label, privacy: .public)")
            }

        case .completed(let route):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .watching(route))
            logger.info("Live switch completed for \(instanceID, privacy: .public) at build \(watcher.target?.build ?? 0, privacy: .public)")

        case .cancelled(let route):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .watching(route))
            logger.info("Live switch cancelled before interruption for \(instanceID, privacy: .public)")

        case .failed(let failure, let route):
            if wasWaitingForStart, let snapshot {
                adapter.clearContinuationIfExact(Self.continuationMessage, in: snapshot)
            }
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .failed(failure))
            logger.error("Live switch failed for \(instanceID, privacy: .public), route \(route.label, privacy: .public), code \(failure.rawValue, privacy: .public)")
        }
    }

    private func handleFailure(
        _ failure: LiveSwitchFailure,
        route: NativeRoute,
        instanceID: String,
        watcher: Watcher,
        snapshot: CodexAXSnapshot?
    ) {
        let action = watcher.machine.fail(failure, route: route)
        handle(
            action, instanceID: instanceID, watcher: watcher,
            snapshot: snapshot, wasWaitingForStart: false)
    }

    private func publishMachineStatus(
        _ state: LiveSwitchStateMachine.State,
        for instanceID: String,
        fallback: NativeRoute?
    ) {
        switch state {
        case .observing(let route):
            if let route = route ?? fallback {
                statuses[instanceID] = LiveSwitchInstanceStatus(phase: .watching(route))
            }
        case .pending(_, let requested, _, _),
             .waitingForIdle(let requested, _, _),
             .waitingForStart(let requested, _, _):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .switching(requested))
        case .failed(_, let reason):
            statuses[instanceID] = LiveSwitchInstanceStatus(phase: .failed(reason))
        }
    }

    private func isSwitchInFlight(_ state: LiveSwitchStateMachine.State) -> Bool {
        switch state {
        case .pending, .waitingForIdle, .waitingForStart:
            true
        case .observing, .failed:
            false
        }
    }

    private func isWaitingForControlTransition(_ state: LiveSwitchStateMachine.State) -> Bool {
        switch state {
        case .waitingForIdle, .waitingForStart:
            true
        case .observing, .pending, .failed:
            false
        }
    }

    private func isWaitingForStart(_ state: LiveSwitchStateMachine.State) -> Bool {
        if case .waitingForStart = state { return true }
        return false
    }

    private func clearPendingContinuationIfNeeded(_ watcher: Watcher) {
        guard isWaitingForStart(watcher.machine.state), let snapshot = watcher.lastSnapshot else {
            return
        }
        adapter.clearContinuationIfExact(Self.continuationMessage, in: snapshot)
    }

    /// Re-resolves the PID and process-start fingerprint immediately before
    /// either AX write. It then takes a new semantic snapshot so a target,
    /// window, route, safety, or turn-state change cannot reuse stale controls.
    private func revalidatedSnapshot(
        for watcher: Watcher,
        expected: CodexAXSnapshot?,
        route: NativeRoute,
        turnIsActive: Bool
    ) -> Result<CodexAXSnapshot, LiveSwitchFailure> {
        guard let cli, let target = watcher.target, let expected,
              target.state == .running
        else { return .failure(.processChanged) }
        let result = InstanceStore.runProcess(
            cli: cli, arguments: ["live-switch", "target", target.instanceID])
        guard case .success(let output) = result,
              let current = LiveSwitchTarget.parse(output), current == target
        else { return .failure(.processChanged) }
        switch adapter.inspect(current) {
        case .unavailable(.notFrontmost):
            return .failure(.focusChanged)
        case .unavailable(let failure):
            return .failure(failure)
        case .snapshot(let fresh):
            guard fresh.route == route else { return .failure(.routeChanged) }
            guard fresh.windowToken == expected.windowToken else {
                return .failure(.focusChanged)
            }
            if let failure = fresh.safetyFailure { return .failure(failure) }
            guard fresh.turnIsActive == turnIsActive else {
                return .failure(turnIsActive ? .interruptFailed : .composerWriteFailed)
            }
            return .success(fresh)
        }
    }

    private func persistEnabledInstances() {
        defaults.set(enabledInstanceIDs.sorted(), forKey: Self.preferencesKey)
    }
}
