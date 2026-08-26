import Foundation
import HLSCore
#if canImport(Observation)
import Observation

@MainActor
public protocol FeedBufferControllable: AnyObject {
    func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy) async
    func play()
    func pause()
    func stop()
    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async

    var state: PlayerState { get }
    var configuration: ProxyPlayerConfiguration { get }
}

public struct FeedBufferPolicy: Sendable, Equatable {
    public var maxLiveNeighbors: Int
    public var maxVODNeighbors: Int
    public var activeBufferSeconds: TimeInterval
    public var warmBufferSeconds: TimeInterval
    public var coldBufferSeconds: TimeInterval
    public var totalMemoryBudgetMegabytes: Int
    public var cooldownDelay: TimeInterval

    public init(
        maxLiveNeighbors: Int = 1,
        maxVODNeighbors: Int = 1,
        activeBufferSeconds: TimeInterval = 8,
        warmBufferSeconds: TimeInterval = 4,
        coldBufferSeconds: TimeInterval = 0,
        totalMemoryBudgetMegabytes: Int = 256,
        cooldownDelay: TimeInterval = 0.75
    ) {
        self.maxLiveNeighbors = max(0, maxLiveNeighbors)
        self.maxVODNeighbors = max(0, maxVODNeighbors)
        self.activeBufferSeconds = max(0, activeBufferSeconds)
        self.warmBufferSeconds = max(0, warmBufferSeconds)
        self.coldBufferSeconds = max(0, coldBufferSeconds)
        self.totalMemoryBudgetMegabytes = max(0, totalMemoryBudgetMegabytes)
        self.cooldownDelay = max(0, cooldownDelay)
    }
}

public struct FeedPlayerDescriptor: Sendable, Equatable {
    public enum StreamKind: Sendable, Equatable {
        case live
        case vod
    }

    public let id: String
    public var index: Int
    public var kind: StreamKind
    public var priority: Int
    public var url: URL
    public var qualityOverride: HLSRewriteConfiguration.QualityPolicy?
    /// Estimated peak memory used while this player is active or warm.
    public var estimatedMemoryMegabytes: Int

    public init(
        id: String,
        index: Int,
        kind: StreamKind,
        priority: Int = 0,
        url: URL,
        qualityOverride: HLSRewriteConfiguration.QualityPolicy? = nil,
        estimatedMemoryMegabytes: Int = 32
    ) {
        self.id = id
        self.index = index
        self.kind = kind
        self.priority = priority
        self.url = url
        self.qualityOverride = qualityOverride
        self.estimatedMemoryMegabytes = max(0, estimatedMemoryMegabytes)
    }
}

public enum FeedBufferEvent: Sendable, Equatable {
    case enteredWarmSet(FeedPlayerDescriptor)
    case exitedWarmSet(FeedPlayerDescriptor)
    case bufferLevelChanged(FeedPlayerDescriptor, deltaSeconds: TimeInterval)
}

public struct FeedPlayerSnapshot: Sendable, Equatable {
    public let descriptor: FeedPlayerDescriptor
    public let state: PlayerState
    public let role: FeedBufferController.Role
}

public struct FeedBufferTelemetry: Sendable {
    public var onWarmSetChanged: @Sendable ([FeedPlayerSnapshot]) -> Void
    public var onEvent: @Sendable (FeedBufferEvent) -> Void

    public init(
        onWarmSetChanged: @escaping @Sendable ([FeedPlayerSnapshot]) -> Void = { _ in },
        onEvent: @escaping @Sendable (FeedBufferEvent) -> Void = { _ in }
    ) {
        self.onWarmSetChanged = onWarmSetChanged
        self.onEvent = onEvent
    }
}

@Observable
@MainActor
public final class FeedBufferController {
    public enum Role: Sendable, Equatable {
        case active
        case warm
        case cold
    }

    public enum ScrollDirection: Sendable {
        case up
        case down
        case stationary
    }

    public struct Handle: Hashable, Sendable {
        fileprivate let id: UUID
        public init() { self.id = UUID() }
    }

    @MainActor
    private final class Entry {
        let handle: Handle
        let player: FeedBufferControllable
        var descriptor: FeedPlayerDescriptor
        let baseConfiguration: ProxyPlayerConfiguration
        var role: Role = .cold
        var loadTask: Task<Void, Never>?
        var cooldownTask: Task<Void, Never>?
        var observationTask: Task<Void, Never>?
        var isLoaded = false
        var isLoading = false
        var loadGeneration: UInt = 0
        var needsRoleAction = false
        var lastBufferSeconds: TimeInterval = 0
        var appliedBufferSeconds: TimeInterval?

        init(handle: Handle, player: FeedBufferControllable, descriptor: FeedPlayerDescriptor) {
            self.handle = handle
            self.player = player
            self.descriptor = descriptor
            self.baseConfiguration = player.configuration
        }

        func cancelTasks() {
            loadTask?.cancel()
            cooldownTask?.cancel()
            observationTask?.cancel()
            loadTask = nil
            cooldownTask = nil
            observationTask = nil
        }
    }

    private var policy: FeedBufferPolicy
    private var telemetry: FeedBufferTelemetry
    private var entries: [Handle: Entry] = [:]
    private var visibleIndex: Int?
    private var lastWarmSnapshot: [FeedPlayerSnapshot] = []

    /// Bindable property for scroll position. Set this to the ID of the currently visible item.
    public var visibleItemID: String? {
        didSet {
            guard visibleItemID != oldValue else { return }
            let newIndex = visibleItemID.flatMap { id in
                entries.values.first { $0.descriptor.id == id }?.descriptor.index
            }
            let oldIndex = oldValue.flatMap { id in
                entries.values.first { $0.descriptor.id == id }?.descriptor.index
            }
            guard let newIndex else {
                visibleIndex = nil
                reevaluateAssignments()
                return
            }

            let direction: ScrollDirection
            if let oldIndex {
                if newIndex > oldIndex {
                    direction = .down
                } else if newIndex < oldIndex {
                    direction = .up
                } else {
                    direction = .stationary
                }
            } else {
                direction = .stationary
            }
            updateVisibleIndex(newIndex, direction: direction)
        }
    }

    public init(policy: FeedBufferPolicy, telemetry: FeedBufferTelemetry = .init()) {
        self.policy = policy
        self.telemetry = telemetry
    }

    public func register(player: FeedBufferControllable, descriptor: FeedPlayerDescriptor) -> Handle {
        let handle = Handle()
        let entry = Entry(handle: handle, player: player, descriptor: descriptor)
        entries[handle] = entry
        if descriptor.id == visibleItemID {
            visibleIndex = descriptor.index
        }
        startBufferObservation(for: entry)
        reevaluateAssignments()
        return handle
    }

    public func updateDescriptor(for handle: Handle, descriptor: FeedPlayerDescriptor) {
        guard let entry = entries[handle] else { return }
        let oldDescriptor = entry.descriptor
        entry.descriptor = descriptor
        if descriptor.url != oldDescriptor.url {
            entry.loadGeneration &+= 1
            entry.isLoaded = false
            entry.loadTask?.cancel()
            if !entry.isLoading {
                entry.loadTask = nil
            }
            entry.needsRoleAction = entry.role != .cold
            entry.player.stop()
        }
        if let visibleItemID {
            if descriptor.id == visibleItemID {
                visibleIndex = descriptor.index
            } else if oldDescriptor.id == visibleItemID {
                visibleIndex = entries.values.first {
                    $0.descriptor.id == visibleItemID
                }?.descriptor.index
            }
        }
        reevaluateAssignments()
    }

    public func unregister(handle: Handle) {
        guard let entry = entries.removeValue(forKey: handle) else { return }
        entry.cancelTasks()
        entry.player.pause()
        entry.player.stop()
        if entry.role != .cold {
            telemetry.onEvent(.exitedWarmSet(entry.descriptor))
        }
        if entry.descriptor.id == visibleItemID {
            visibleIndex = entries.values.first {
                $0.descriptor.id == visibleItemID
            }?.descriptor.index
        }
        reevaluateAssignments()
    }

    public func updateVisibleIndex(_ index: Int, direction: ScrollDirection = .stationary) {
        visibleIndex = index
        reevaluateAssignments(direction: direction)
    }

    /// Temporarily pause the active player during scrolling.
    public func pauseActivePlayer() {
        guard let active = entries.values.first(where: { $0.role == .active }) else { return }
        active.player.pause()
    }

    /// Resume the active player after scrolling stops.
    public func resumeActivePlayer() {
        guard let active = entries.values.first(where: { $0.role == .active }) else { return }
        active.player.play()
    }

    public func updatePolicy(_ policy: FeedBufferPolicy) {
        self.policy = policy
        entries.values.forEach { applyBufferPolicy(for: $0.role, to: $0) }
        reevaluateAssignments()
    }

    public func updateTelemetry(_ telemetry: FeedBufferTelemetry) {
        self.telemetry = telemetry
        publishWarmSet()
    }

    private func reevaluateAssignments(direction: ScrollDirection = .stationary) {
        guard !entries.isEmpty else {
            publishWarmSet()
            return
        }
        guard let visibleIndex else {
            entries.values.forEach { assign($0, to: .cold) }
            publishWarmSet()
            return
        }

        let activeEntry = resolveActiveEntry(targetIndex: visibleIndex)
        var warmEntries: [Entry] = []

        if let activeEntry {
            let candidates = neighborCandidates(excluding: activeEntry.handle, around: visibleIndex, direction: direction)
            var liveCount = 0
            var vodCount = 0
            for candidate in candidates {
                switch candidate.descriptor.kind {
                case .live:
                    guard liveCount < policy.maxLiveNeighbors else { continue }
                    liveCount += 1
                    warmEntries.append(candidate)
                case .vod:
                    guard vodCount < policy.maxVODNeighbors else { continue }
                    vodCount += 1
                    warmEntries.append(candidate)
                }
            }
        }

        enforceMemoryBudget(active: activeEntry, warmEntries: &warmEntries)

        entries.values.forEach { entry in
            if let activeEntry, entry.handle == activeEntry.handle {
                assign(entry, to: .active)
            } else if warmEntries.contains(where: { $0.handle == entry.handle }) {
                assign(entry, to: .warm)
            } else {
                assign(entry, to: .cold)
            }
        }

        publishWarmSet()
    }

    private func resolveActiveEntry(targetIndex: Int) -> Entry? {
        if let exact = entries.values.first(where: { $0.descriptor.index == targetIndex }) {
            return exact
        }
        return entries.values.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs.descriptor.index - targetIndex)
            let rhsDistance = abs(rhs.descriptor.index - targetIndex)
            if lhsDistance == rhsDistance {
                return lhs.descriptor.priority > rhs.descriptor.priority
            }
            return lhsDistance < rhsDistance
        })
    }

    private func neighborCandidates(excluding handle: Handle, around index: Int, direction: ScrollDirection) -> [Entry] {
        entries.values
            .filter { $0.handle != handle }
            .sorted { lhs, rhs in
                let lhsScore = neighborScore(for: lhs, around: index, direction: direction)
                let rhsScore = neighborScore(for: rhs, around: index, direction: direction)
                if lhsScore == rhsScore {
                    if lhs.descriptor.priority == rhs.descriptor.priority {
                        return lhs.descriptor.index < rhs.descriptor.index
                    }
                    return lhs.descriptor.priority > rhs.descriptor.priority
                }
                return lhsScore < rhsScore
            }
    }

    private func neighborScore(for entry: Entry, around index: Int, direction: ScrollDirection) -> Int {
        let distance = abs(entry.descriptor.index - index)
        if distance == 0 { return 0 }
        let prefersForward = direction == .down
        let prefersBackward = direction == .up
        let isAhead = entry.descriptor.index > index
        if prefersForward && isAhead {
            return (distance * 2) - 1
        }
        if prefersBackward && !isAhead {
            return (distance * 2) - 1
        }
        return distance * 2
    }

    private func enforceMemoryBudget(active: Entry?, warmEntries: inout [Entry]) {
        guard policy.totalMemoryBudgetMegabytes > 0 else { return }
        let budgetBytes = bytes(fromMegabytes: policy.totalMemoryBudgetMegabytes)
        var totalBytes = active.map(memoryCost(for:)) ?? 0
        for entry in warmEntries {
            let (sum, overflow) = totalBytes.addingReportingOverflow(memoryCost(for: entry))
            totalBytes = overflow ? .max : sum
        }
        while totalBytes > budgetBytes, !warmEntries.isEmpty {
            if let removed = warmEntries.popLast() {
                totalBytes -= memoryCost(for: removed)
            }
        }
    }

    private func assign(_ entry: Entry, to role: Role) {
        let previousRole = entry.role
        let needsRoleAction = previousRole != role || entry.needsRoleAction
        entry.role = role
        applyBufferPolicy(for: role, to: entry)

        guard needsRoleAction else { return }
        entry.needsRoleAction = false

        switch role {
        case .active:
            cancelCooldown(for: entry)
            ensurePrepared(entry)
            entry.player.play()
        case .warm:
            cancelCooldown(for: entry)
            ensurePrepared(entry)
            entry.player.pause()
        case .cold:
            entry.player.pause()
            scheduleStop(for: entry)
        }

        if previousRole == .cold, role != .cold {
            telemetry.onEvent(.enteredWarmSet(entry.descriptor))
        } else if previousRole != .cold, role == .cold {
            telemetry.onEvent(.exitedWarmSet(entry.descriptor))
        }
    }

    private func ensurePrepared(_ entry: Entry) {
        guard !entry.isLoading else { return }
        guard !entry.isLoaded else { return }
        entry.isLoading = true
        let url = entry.descriptor.url
        let quality = entry.descriptor.qualityOverride ?? entry.baseConfiguration.qualityPolicy
        let generation = entry.loadGeneration
        entry.loadTask?.cancel()
        entry.loadTask = Task { [weak self, weak entry] in
            guard let entry else { return }
            await entry.player.load(from: url, quality: quality)
            await MainActor.run {
                guard let self else { return }
                guard self.entries[entry.handle] === entry else {
                    let playerWasReused = self.entries.values.contains {
                        $0.player === entry.player
                    }
                    if !playerWasReused {
                        entry.player.stop()
                    }
                    return
                }
                entry.isLoading = false
                entry.loadTask = nil
                guard generation == entry.loadGeneration,
                      url == entry.descriptor.url,
                      !Task.isCancelled else {
                    if entry.role != .cold {
                        self.ensurePrepared(entry)
                    }
                    return
                }
                entry.isLoaded = true
            }
        }
    }

    private func cancelCooldown(for entry: Entry) {
        entry.cooldownTask?.cancel()
        entry.cooldownTask = nil
    }

    private func scheduleStop(for entry: Entry) {
        cancelCooldown(for: entry)
        let delay = policy.cooldownDelay
        entry.cooldownTask = Task { [weak self, weak entry] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, let entry,
                      self.entries[entry.handle] === entry,
                      entry.role == .cold else { return }
                entry.player.stop()
                entry.isLoaded = false
                entry.loadGeneration &+= 1
                entry.loadTask?.cancel()
                if !entry.isLoading {
                    entry.loadTask = nil
                }
                entry.cooldownTask = nil
            }
        }
    }

    private func applyBufferPolicy(for role: Role, to entry: Entry) {
        let targetSeconds: TimeInterval
        switch role {
        case .active:
            targetSeconds = max(policy.activeBufferSeconds, entry.baseConfiguration.bufferPolicy.targetBufferSeconds)
        case .warm:
            targetSeconds = min(policy.warmBufferSeconds, entry.baseConfiguration.bufferPolicy.targetBufferSeconds)
        case .cold:
            targetSeconds = min(policy.coldBufferSeconds, entry.baseConfiguration.bufferPolicy.targetBufferSeconds)
        }
        guard entry.appliedBufferSeconds != targetSeconds else { return }
        entry.appliedBufferSeconds = targetSeconds
        var configuration = entry.baseConfiguration
        configuration.bufferPolicy.targetBufferSeconds = targetSeconds
        Task { [weak entry] in
            guard let entry else { return }
            await entry.player.updateConfiguration(configuration)
        }
    }

    private func startBufferObservation(for entry: Entry) {
        entry.observationTask = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            await self.observeBufferByPolling(entry)
        }
    }

    @MainActor
    private func observeBufferByPolling(_ entry: Entry) async {
        var lastValue = entry.player.state.bufferDepthSeconds
        entry.lastBufferSeconds = lastValue
        while !Task.isCancelled, entries[entry.handle] != nil {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard entries[entry.handle] != nil else { break }
            let newValue = entry.player.state.bufferDepthSeconds
            let delta = newValue - lastValue
            if abs(delta) >= 0.25 {
                telemetry.onEvent(.bufferLevelChanged(entry.descriptor, deltaSeconds: delta))
            }
            lastValue = newValue
            entry.lastBufferSeconds = newValue
        }
    }

    private func publishWarmSet() {
        let snapshots = entries.values
            .filter { $0.role != .cold }
            .sorted(by: { $0.descriptor.index < $1.descriptor.index })
            .map { entry in
                FeedPlayerSnapshot(descriptor: entry.descriptor, state: entry.player.state, role: entry.role)
            }
        guard snapshots != lastWarmSnapshot else { return }
        lastWarmSnapshot = snapshots
        telemetry.onWarmSetChanged(snapshots)
    }

    private func memoryCost(for entry: Entry) -> Int64 {
        bytes(fromMegabytes: entry.descriptor.estimatedMemoryMegabytes)
    }

    private func bytes(fromMegabytes megabytes: Int) -> Int64 {
        let clampedMegabytes = max(0, megabytes)
        let (bytes, overflow) = Int64(clampedMegabytes).multipliedReportingOverflow(by: 1_048_576)
        return overflow ? .max : bytes
    }
}

#if canImport(AVFoundation)
extension ProxyHLSPlayer: FeedBufferControllable {}
#endif
#endif
