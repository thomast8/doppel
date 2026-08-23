import Foundation

struct LiveSwitchStateMachine {
    struct Observation: Equatable {
        let route: NativeRoute
        let turnIsActive: Bool
        let windowToken: String
        let safetyFailure: LiveSwitchFailure?
    }

    enum Action: Equatable {
        case none
        case pressStop(NativeRoute)
        case submitContinuation(NativeRoute)
        case completed(NativeRoute)
        case cancelled(NativeRoute)
        case failed(LiveSwitchFailure, NativeRoute)
    }

    enum State: Equatable {
        case observing(NativeRoute?)
        case pending(
            original: NativeRoute,
            requested: NativeRoute,
            windowToken: String,
            startedAt: TimeInterval)
        case waitingForIdle(
            requested: NativeRoute,
            windowToken: String,
            deadline: TimeInterval)
        case waitingForStart(
            requested: NativeRoute,
            windowToken: String,
            deadline: TimeInterval)
        case failed(blockedRoute: NativeRoute, reason: LiveSwitchFailure)
    }

    private let debounce: TimeInterval
    private let interruptTimeout: TimeInterval
    private let startTimeout: TimeInterval
    private(set) var state: State = .observing(nil)

    init(debounce: TimeInterval = 0.25,
         interruptTimeout: TimeInterval = 10,
         startTimeout: TimeInterval = 5) {
        self.debounce = debounce
        self.interruptTimeout = interruptTimeout
        self.startTimeout = startTimeout
    }

    mutating func observe(_ observation: Observation, at now: TimeInterval) -> Action {
        switch state {
        case .observing(nil):
            state = .observing(observation.route)
            return .none

        case .observing(let original?):
            guard observation.route != original else { return .none }
            guard observation.turnIsActive else {
                state = .observing(observation.route)
                return .none
            }
            if let failure = observation.safetyFailure {
                return transitionToFailure(failure, route: observation.route)
            }
            state = .pending(
                original: original, requested: observation.route,
                windowToken: observation.windowToken, startedAt: now)
            return .none

        case .pending(let original, let requested, let windowToken, let startedAt):
            if observation.route != requested {
                guard observation.route != original else {
                    state = .observing(original)
                    return .cancelled(original)
                }
                guard observation.turnIsActive else {
                    state = .observing(observation.route)
                    return .cancelled(observation.route)
                }
                if let failure = observation.safetyFailure {
                    return transitionToFailure(failure, route: observation.route)
                }
                state = .pending(
                    original: original, requested: observation.route,
                    windowToken: observation.windowToken, startedAt: now)
                return .none
            }
            guard observation.windowToken == windowToken else {
                return transitionToFailure(.focusChanged, route: requested)
            }
            guard observation.turnIsActive else {
                state = .observing(requested)
                return .cancelled(requested)
            }
            if let failure = observation.safetyFailure {
                return transitionToFailure(failure, route: requested)
            }
            guard now - startedAt >= debounce else { return .none }
            state = .waitingForIdle(
                requested: requested, windowToken: windowToken,
                deadline: now + interruptTimeout)
            return .pressStop(requested)

        case .waitingForIdle(let requested, let windowToken, let deadline):
            guard observation.route == requested else {
                return transitionToFailure(.routeChanged, route: requested)
            }
            guard observation.windowToken == windowToken else {
                return transitionToFailure(.focusChanged, route: requested)
            }
            if let failure = observation.safetyFailure {
                return transitionToFailure(failure, route: requested)
            }
            guard now < deadline else {
                return transitionToFailure(.interruptTimedOut, route: requested)
            }
            guard !observation.turnIsActive else { return .none }
            state = .waitingForStart(
                requested: requested, windowToken: windowToken,
                deadline: now + startTimeout)
            return .submitContinuation(requested)

        case .waitingForStart(let requested, let windowToken, let deadline):
            guard observation.route == requested else {
                return transitionToFailure(.routeChanged, route: requested)
            }
            guard observation.windowToken == windowToken else {
                return transitionToFailure(.focusChanged, route: requested)
            }
            guard now < deadline else {
                return transitionToFailure(.startTimedOut, route: requested)
            }
            guard observation.turnIsActive else { return .none }
            state = .observing(requested)
            return .completed(requested)

        case .failed(let blockedRoute, _):
            guard observation.route != blockedRoute else { return .none }
            guard observation.turnIsActive else {
                state = .observing(observation.route)
                return .none
            }
            if let failure = observation.safetyFailure {
                return transitionToFailure(failure, route: observation.route)
            }
            state = .pending(
                original: blockedRoute, requested: observation.route,
                windowToken: observation.windowToken, startedAt: now)
            return .none
        }
    }

    mutating func fail(_ failure: LiveSwitchFailure, route: NativeRoute) -> Action {
        transitionToFailure(failure, route: route)
    }

    /// Keeps a switch alive across the brief interval where Electron replaces
    /// Stop with Send (or Send with Stop) and exposes neither control to AX.
    /// Permanent contract loss still reaches the same bounded timeout.
    mutating func waitWithoutObservation(at now: TimeInterval) -> Action {
        switch state {
        case .waitingForIdle(let requested, _, let deadline) where now >= deadline:
            return transitionToFailure(.interruptTimedOut, route: requested)
        case .waitingForStart(let requested, _, let deadline) where now >= deadline:
            return transitionToFailure(.startTimedOut, route: requested)
        default:
            return .none
        }
    }

    mutating func reset() {
        state = .observing(nil)
    }

    private mutating func transitionToFailure(
        _ failure: LiveSwitchFailure, route: NativeRoute
    ) -> Action {
        state = .failed(blockedRoute: route, reason: failure)
        return .failed(failure, route)
    }
}
