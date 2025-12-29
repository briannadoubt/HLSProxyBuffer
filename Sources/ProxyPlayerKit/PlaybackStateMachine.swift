import Foundation

/// Formal playback state machine for the HLS proxy player
public struct PlaybackStateMachine: Sendable {
    public enum State: String, Sendable, CaseIterable {
        case idle
        case loading
        case buffering
        case playing
        case paused
        case seeking
        case stalled
        case ended
        case failed
    }

    public enum Event: Sendable {
        case load(URL)
        case loadComplete
        case loadFailed(Error)
        case play
        case pause
        case stop
        case seek(TimeInterval)
        case seekComplete
        case bufferEmpty
        case bufferReady
        case reachEnd
        case stall
        case recover
        case error(Error)
    }

    public struct Transition: Sendable {
        public let from: State
        public let event: Event
        public let to: State
        public let timestamp: Date

        public init(from: State, event: Event, to: State, timestamp: Date = Date()) {
            self.from = from
            self.event = event
            self.to = to
            self.timestamp = timestamp
        }
    }

    public private(set) var currentState: State
    public private(set) var previousState: State?
    public private(set) var lastTransition: Transition?
    public private(set) var stateHistory: [Transition]
    public private(set) var lastError: Error?
    public private(set) var loadedURL: URL?

    private let maxHistorySize: Int
    private var onTransition: ((Transition) -> Void)?

    public init(maxHistorySize: Int = 50) {
        self.currentState = .idle
        self.previousState = nil
        self.lastTransition = nil
        self.stateHistory = []
        self.lastError = nil
        self.loadedURL = nil
        self.maxHistorySize = maxHistorySize
    }

    public mutating func setTransitionHandler(_ handler: @escaping (Transition) -> Void) {
        onTransition = handler
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> State {
        let nextState = computeNextState(for: event)

        if nextState != currentState {
            let transition = Transition(from: currentState, event: event, to: nextState)
            previousState = currentState
            currentState = nextState
            lastTransition = transition

            stateHistory.append(transition)
            if stateHistory.count > maxHistorySize {
                stateHistory.removeFirst()
            }

            // Handle side effects
            handleSideEffects(for: event)

            onTransition?(transition)
        }

        return currentState
    }

    private func computeNextState(for event: Event) -> State {
        switch (currentState, event) {
        // From Idle
        case (.idle, .load):
            return .loading
        case (.idle, _):
            return .idle

        // From Loading
        case (.loading, .loadComplete):
            return .buffering
        case (.loading, .loadFailed):
            return .failed
        case (.loading, .stop):
            return .idle
        case (.loading, _):
            return .loading

        // From Buffering
        case (.buffering, .bufferReady):
            return .playing
        case (.buffering, .pause):
            return .paused
        case (.buffering, .stop):
            return .idle
        case (.buffering, .error):
            return .failed
        case (.buffering, .stall):
            return .stalled
        case (.buffering, _):
            return .buffering

        // From Playing
        case (.playing, .pause):
            return .paused
        case (.playing, .stop):
            return .idle
        case (.playing, .seek):
            return .seeking
        case (.playing, .bufferEmpty):
            return .buffering
        case (.playing, .stall):
            return .stalled
        case (.playing, .reachEnd):
            return .ended
        case (.playing, .error):
            return .failed
        case (.playing, _):
            return .playing

        // From Paused
        case (.paused, .play):
            return .playing
        case (.paused, .stop):
            return .idle
        case (.paused, .seek):
            return .seeking
        case (.paused, .error):
            return .failed
        case (.paused, _):
            return .paused

        // From Seeking
        case (.seeking, .seekComplete):
            return previousState == .paused ? .paused : .playing
        case (.seeking, .bufferEmpty):
            return .buffering
        case (.seeking, .stop):
            return .idle
        case (.seeking, .error):
            return .failed
        case (.seeking, _):
            return .seeking

        // From Stalled
        case (.stalled, .recover):
            return previousState ?? .playing
        case (.stalled, .bufferReady):
            return .playing
        case (.stalled, .stop):
            return .idle
        case (.stalled, .error):
            return .failed
        case (.stalled, _):
            return .stalled

        // From Ended
        case (.ended, .play):
            return .seeking  // Will seek to start
        case (.ended, .load):
            return .loading
        case (.ended, .stop):
            return .idle
        case (.ended, _):
            return .ended

        // From Failed
        case (.failed, .load):
            return .loading
        case (.failed, .stop):
            return .idle
        case (.failed, _):
            return .failed
        }
    }

    private mutating func handleSideEffects(for event: Event) {
        switch event {
        case .load(let url):
            loadedURL = url
            lastError = nil
        case .loadFailed(let error), .error(let error):
            lastError = error
        case .stop:
            loadedURL = nil
            lastError = nil
        default:
            break
        }
    }

    // MARK: - State Queries

    public var isPlaying: Bool {
        currentState == .playing
    }

    public var isPaused: Bool {
        currentState == .paused
    }

    public var isLoading: Bool {
        currentState == .loading || currentState == .buffering
    }

    public var isSeeking: Bool {
        currentState == .seeking
    }

    public var canPlay: Bool {
        switch currentState {
        case .paused, .ended, .buffering:
            return true
        default:
            return false
        }
    }

    public var canPause: Bool {
        switch currentState {
        case .playing, .buffering:
            return true
        default:
            return false
        }
    }

    public var canSeek: Bool {
        switch currentState {
        case .playing, .paused:
            return true
        default:
            return false
        }
    }

    public var canStop: Bool {
        currentState != .idle
    }

    // MARK: - State Duration

    public func timeInCurrentState() -> TimeInterval? {
        lastTransition.map { Date().timeIntervalSince($0.timestamp) }
    }

    public func totalTimeInState(_ state: State) -> TimeInterval {
        var total: TimeInterval = 0
        var lastEntry: Transition?

        for transition in stateHistory {
            if let entry = lastEntry, entry.to == state {
                total += transition.timestamp.timeIntervalSince(entry.timestamp)
            }
            lastEntry = transition
        }

        // Add current state duration if applicable
        if currentState == state, let last = lastTransition {
            total += Date().timeIntervalSince(last.timestamp)
        }

        return total
    }
}

// MARK: - State Machine Validation

public extension PlaybackStateMachine {
    /// Validates that a transition is allowed
    static func isValidTransition(from: State, event: Event) -> Bool {
        var machine = PlaybackStateMachine()
        machine.currentState = from
        let nextState = machine.computeNextState(for: event)
        return nextState != from || isNoOpAllowed(for: event)
    }

    private static func isNoOpAllowed(for event: Event) -> Bool {
        // Some events are allowed to be no-ops
        switch event {
        case .bufferReady, .recover:
            return true
        default:
            return false
        }
    }

    /// Returns all valid events for a given state
    static func validEvents(for state: State) -> [Event] {
        // Representative events for each type
        let allEvents: [Event] = [
            .load(URL(string: "test://")!),
            .loadComplete,
            .loadFailed(NSError(domain: "", code: 0)),
            .play,
            .pause,
            .stop,
            .seek(0),
            .seekComplete,
            .bufferEmpty,
            .bufferReady,
            .reachEnd,
            .stall,
            .recover,
            .error(NSError(domain: "", code: 0))
        ]

        return allEvents.filter { isValidTransition(from: state, event: $0) }
    }
}
