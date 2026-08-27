import AVFoundation
import Foundation
import HLSCore
import Observation

/// A read-only view of one engine-owned playback lease.
public struct HLSFeedPlayback: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case loading
        case warm
        case focused
        case failed(String)
    }

    public let itemID: FeedItemID
    public let generation: FeedNavigationGeneration
    public let role: FeedPlan.Role
    public let phase: Phase
    public let state: PlayerState

    public var isImmediatelyPlayable: Bool {
        phase == .warm || phase == .focused
    }
}

/// Fixed-size state for the automatic feed engine.
public struct HLSFeedEngineSnapshot: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let itemID: FeedItemID
        public let generation: FeedNavigationGeneration
        public let message: String
    }

    public let generation: FeedNavigationGeneration?
    public let targetFocusedItemID: FeedItemID?
    public let activeItemID: FeedItemID?
    public let requestedDestinationItemID: FeedItemID?
    public let playbacks: [HLSFeedPlayback]
    public let failures: [Failure]
    public let poolOccupancy: Int
    public let allocatedPlayerCount: Int
    public let activeLoadCount: Int
    public let maximumObservedPoolOccupancy: Int
    public let staleCompletionCount: Int

    public static let empty = Self(
        generation: nil,
        targetFocusedItemID: nil,
        activeItemID: nil,
        requestedDestinationItemID: nil,
        playbacks: [],
        failures: [],
        poolOccupancy: 0,
        allocatedPlayerCount: 0,
        activeLoadCount: 0,
        maximumObservedPoolOccupancy: 0,
        staleCompletionCount: 0
    )

    public func playback(for itemID: FeedItemID) -> HLSFeedPlayback? {
        playbacks.first { $0.itemID == itemID }
    }
}

public enum HLSFeedEngineError: Error, Equatable, LocalizedError, Sendable {
    case stopped
    case noFocusedItem
    case itemUnavailable(FeedItemID)
    case untypedClipSequenceRequiresCompatibility(FeedItemID)
    case playerFailed(FeedItemID, String)

    public var errorDescription: String? {
        switch self {
        case .stopped:
            "The feed engine has been stopped"
        case .noFocusedItem:
            "The feed engine has no focused playback item"
        case .itemUnavailable(let itemID):
            "The feed item is not currently owned by the playback pool: \(itemID)"
        case .untypedClipSequenceRequiresCompatibility(let itemID):
            "Feed item \(itemID) must use compatibleClips to create one stitched playback timeline"
        case .playerFailed(let itemID, let message):
            "Feed item \(itemID) failed to load: \(message)"
        }
    }
}

@MainActor
protocol HLSFeedPlayerSession: AnyObject {
    var state: PlayerState { get }
    var feedPlatformPlayer: AVPlayer? { get }

    func stateUpdates() -> AsyncStream<PlayerState>
    func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy) async
    func load(clips: [ProxyPlaybackClip]) async throws
    func play()
    func pause()
    func setPlaybackRate(_ rate: Float)
    func jumpToLive() async throws
    func seek(secondsBehindLiveEdge: TimeInterval) async throws
    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async
    func stopAndWait() async
    func restartPlayback() async
}

extension ProxyHLSPlayer: HLSFeedPlayerSession {
    var feedPlatformPlayer: AVPlayer? { player }

    func restartPlayback() async {
        guard let player else { return }
        player.currentItem?.cancelPendingSeeks()
        await player.seek(to: .zero)
        play()
    }
}

/// Owns predictive preparation, a bounded reusable player pool, and atomic
/// focus handoff for an ordered collection of HLS items.
///
/// Applications provide items, one typed policy, and UI-independent viewport
/// signals. The engine owns every `AVPlayer`, proxy listener, scheduler,
/// observer, and cache lease needed by the active working set.
@Observable
@MainActor
public final class HLSFeedEngine {
    private struct Lease {
        let token: UUID
        let itemID: FeedItemID
        var generation: FeedNavigationGeneration
        var role: FeedPlan.Role
        let source: FeedPlaybackSource
        var phase: HLSFeedPlayback.Phase
        var state: PlayerState
        var didCompleteInitialLoad: Bool
    }

    @MainActor
    private final class Slot {
        let id = UUID()
        let session: any HLSFeedPlayerSession
        var lease: Lease?
        var loadTask: Task<Void, Never>?
        var observationTask: Task<Void, Never>?
        var releaseTask: Task<Void, Never>?
        var playbackEndObserver: NSObjectProtocol?

        init(session: any HLSFeedPlayerSession) {
            self.session = session
        }

        func cancelLeaseObservers() {
            observationTask?.cancel()
            observationTask = nil
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
                self.playbackEndObserver = nil
            }
        }
    }

    typealias SessionFactory = @MainActor (ProxyPlayerConfiguration) -> any HLSFeedPlayerSession

    public private(set) var snapshot = HLSFeedEngineSnapshot.empty
    public private(set) var requestedDestinationItemID: FeedItemID?

    @ObservationIgnored private var items: [FeedPlaybackItem]
    @ObservationIgnored private var itemsByID: [FeedItemID: FeedPlaybackItem]
    @ObservationIgnored private var basePolicy: FeedPlaybackPolicy
    @ObservationIgnored private var effectivePolicy: FeedPlaybackPolicy
    @ObservationIgnored private var playerConfiguration: ProxyPlayerConfiguration
    @ObservationIgnored private let coordinator: FeedCoordinator
    @ObservationIgnored private let sessionFactory: SessionFactory
    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private var slotIDByItemID: [FeedItemID: UUID] = [:]
    @ObservationIgnored private var desiredItemIDs: Set<FeedItemID> = []
    @ObservationIgnored private var failuresByItemID: [FeedItemID: HLSFeedEngineSnapshot.Failure] = [:]
    @ObservationIgnored private var targetFocusedItemID: FeedItemID?
    @ObservationIgnored private var activeItemID: FeedItemID?
    @ObservationIgnored private var latestCoordinatorSnapshot: FeedCoordinatorSnapshot?
    @ObservationIgnored private var coordinatorObservationTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<HLSFeedEngineSnapshot>.Continuation] = [:]
    @ObservationIgnored private var maximumObservedPoolOccupancy = 0
    @ObservationIgnored private var staleCompletionCount = 0
    @ObservationIgnored private var isStopped = false

    /// Creates a production engine with one shared bounded cache underneath
    /// predictive preparation and all pooled playback sessions.
    public convenience init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy
    ) throws {
        let validatedPolicy = try policy.validated()
        let sharedCache = Self.makeSharedCache(policy: validatedPolicy)
        let backend = try HLSFeedPreparationBackend(
            policy: validatedPolicy,
            cache: sharedCache
        )
        let coordinator = try FeedCoordinator(
            items: items,
            policy: validatedPolicy,
            backend: backend
        )
        try self.init(
            items: items,
            policy: validatedPolicy,
            coordinator: coordinator,
            sessionFactory: { configuration in
                ProxyHLSPlayer(configuration: configuration, sharedCache: sharedCache)
            }
        )
    }

    init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        coordinator: FeedCoordinator,
        sessionFactory: @escaping SessionFactory
    ) throws {
        let validatedPolicy = try policy.validated()
        self.items = items
        self.itemsByID = try Self.validatedItemsByID(items)
        self.basePolicy = validatedPolicy
        self.effectivePolicy = validatedPolicy
        self.playerConfiguration = try Self.playerConfiguration(for: validatedPolicy)
        self.coordinator = coordinator
        self.sessionFactory = sessionFactory
        startCoordinatorObservation()
    }

    /// Applies one current visibility/focus/velocity/prediction observation.
    /// Warm sessions never autoplay; focus moves only when the destination's
    /// existing player item is ready.
    @discardableResult
    public func update(_ signal: FeedViewportSignal) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let value = try await coordinator.submit(signal)
        if value.generation == signal.generation {
            targetFocusedItemID = signal.focusedItemID
            requestedDestinationItemID = nil
            failuresByItemID.removeAll(keepingCapacity: true)
        }
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Replaces feed contents while retaining leases only for identical items.
    @discardableResult
    public func replaceItems(
        _ items: [FeedPlaybackItem]
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let replacement = try Self.validatedItemsByID(items)
        let value = try await coordinator.replaceItems(items)
        for slot in slots {
            guard let lease = slot.lease,
                  replacement[lease.itemID]?.source != lease.source
            else { continue }
            await release(slot, token: lease.token)
        }
        self.items = items
        self.itemsByID = replacement
        if let targetFocusedItemID, replacement[targetFocusedItemID] == nil {
            self.targetFocusedItemID = nil
        }
        if let requestedDestinationItemID, replacement[requestedDestinationItemID] == nil {
            self.requestedDestinationItemID = nil
        }
        failuresByItemID = failuresByItemID.filter { replacement[$0.key] != nil }
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Revalidates and atomically applies a new base policy.
    @discardableResult
    public func updatePolicy(
        _ policy: FeedPlaybackPolicy
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let validatedPolicy = try policy.validated()
        let configuration = try Self.playerConfiguration(for: validatedPolicy)
        let value = try await coordinator.updatePolicy(validatedPolicy)
        basePolicy = validatedPolicy
        effectivePolicy = validatedPolicy
        playerConfiguration = configuration
        for slot in slots {
            await slot.session.updateConfiguration(playerConfiguration)
        }
        await trimPoolIfNeeded()
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Applies the policy's low-power caps to preparation and player ownership.
    @discardableResult
    public func setLowPowerModeEnabled(
        _ isEnabled: Bool
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let adaptedPolicy = try basePolicy.adaptedForLowPowerMode(isEnabled)
        let configuration = try Self.playerConfiguration(for: adaptedPolicy)
        let value = try await coordinator.setLowPowerModeEnabled(isEnabled)
        effectivePolicy = adaptedPolicy
        playerConfiguration = configuration
        for slot in slots {
            await slot.session.updateConfiguration(playerConfiguration)
        }
        await trimPoolIfNeeded()
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Bounded newest-only state for non-Observation consumers.
    public func updates() -> AsyncStream<HLSFeedEngineSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Waits for currently admitted preparation and player-loading work.
    @discardableResult
    public func waitUntilSettled() async -> HLSFeedEngineSnapshot {
        guard !isStopped else { return snapshot }
        let value = await coordinator.waitUntilIdle()
        acceptCoordinatorSnapshot(value)
        while true {
            let tasks = slots.compactMap(\.loadTask)
            guard !tasks.isEmpty else { break }
            for task in tasks { await task.value }
        }
        return snapshot
    }

    public func playback(for itemID: FeedItemID) -> HLSFeedPlayback? {
        snapshot.playback(for: itemID)
    }

    public func setPlaybackRate(_ rate: Float, for itemID: FeedItemID? = nil) throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        slot.session.setPlaybackRate(rate)
    }

    public func jumpToLive(for itemID: FeedItemID? = nil) async throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        try await slot.session.jumpToLive()
    }

    public func seek(
        secondsBehindLiveEdge: TimeInterval,
        for itemID: FeedItemID? = nil
    ) async throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        try await slot.session.seek(secondsBehindLiveEdge: secondsBehindLiveEdge)
    }

    /// Cancels all preparation, load, observation, grace-period, and listener
    /// work and waits for every pooled session to finish teardown.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let coordinatorObservationTask = coordinatorObservationTask
        coordinatorObservationTask?.cancel()
        self.coordinatorObservationTask = nil
        await coordinator.stop()

        let loadTasks = slots.compactMap(\.loadTask)
        let releaseTasks = slots.compactMap(\.releaseTask)
        let observationTasks = slots.compactMap(\.observationTask)
        for slot in slots {
            slot.loadTask?.cancel()
            slot.releaseTask?.cancel()
            slot.cancelLeaseObservers()
        }
        await coordinatorObservationTask?.value
        for task in loadTasks { await task.value }
        for task in releaseTasks { await task.value }
        for task in observationTasks { await task.value }
        for slot in slots { await slot.session.stopAndWait() }

        slots.removeAll()
        slotIDByItemID.removeAll()
        desiredItemIDs.removeAll()
        failuresByItemID.removeAll()
        activeItemID = nil
        targetFocusedItemID = nil
        requestedDestinationItemID = nil
        latestCoordinatorSnapshot = nil
        rebuildSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// The rendering layer uses this read-only reference; ownership remains in
    /// the engine and disappears when its lease is recycled.
    func platformPlayer(for itemID: FeedItemID) -> AVPlayer? {
        slot(for: itemID)?.session.feedPlatformPlayer
    }

    func notifyPlaybackEnded(for itemID: FeedItemID) async {
        guard let slot = slot(for: itemID), let token = slot.lease?.token else { return }
        await playbackEnded(in: slot, token: token)
    }

    private func startCoordinatorObservation() {
        let coordinator = coordinator
        coordinatorObservationTask = Task { @MainActor [weak self] in
            let updates = await coordinator.updates()
            for await value in updates {
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                self.acceptCoordinatorSnapshot(value)
            }
        }
    }

    private func acceptCoordinatorSnapshot(_ value: FeedCoordinatorSnapshot) {
        guard !isStopped else { return }
        if let current = latestCoordinatorSnapshot?.generation,
           let incoming = value.generation,
           incoming < current {
            return
        }
        latestCoordinatorSnapshot = value
        desiredItemIDs = Set(value.entries.map(\.itemID))

        for slot in slots where slot.lease.map({ !desiredItemIDs.contains($0.itemID) }) == true {
            scheduleRelease(of: slot)
        }

        for entry in value.entries {
            guard case .ready = entry.status,
                  let item = itemsByID[entry.itemID],
                  let generation = value.generation
            else { continue }
            ensureLease(for: item, generation: generation, role: entry.role)
        }

        if let targetFocusedItemID,
           let slot = slot(for: targetFocusedItemID),
           slot.lease.map({ $0.phase == .warm || $0.phase == .focused }) == true {
            activate(slot)
        }
        rebuildSnapshot()
    }

    private func ensureLease(
        for item: FeedPlaybackItem,
        generation: FeedNavigationGeneration,
        role: FeedPlan.Role
    ) {
        if let slot = slot(for: item.id), var lease = slot.lease, lease.source == item.source {
            slot.releaseTask?.cancel()
            slot.releaseTask = nil
            lease.generation = generation
            lease.role = role
            slot.lease = lease
            return
        }

        guard let slot = availableSlot(for: role) else { return }
        failuresByItemID.removeValue(forKey: item.id)
        assign(item, generation: generation, role: role, to: slot)
    }

    private func availableSlot(for role: FeedPlan.Role) -> Slot? {
        if let idle = slots.first(where: { $0.lease == nil }) { return idle }
        if slots.count < effectivePolicy.concurrency.maximumPlayerCount {
            let slot = Slot(session: sessionFactory(playerConfiguration))
            slots.append(slot)
            return slot
        }

        let reclaimable = slots.reversed().first { slot in
            guard let lease = slot.lease else { return true }
            return lease.itemID != activeItemID
                && (!desiredItemIDs.contains(lease.itemID) || lease.role.rawValue > role.rawValue)
        }
        if let reclaimable { return reclaimable }
        if role == .focused {
            return slots.first { $0.lease?.itemID == activeItemID }
        }
        return nil
    }

    private func assign(
        _ item: FeedPlaybackItem,
        generation: FeedNavigationGeneration,
        role: FeedPlan.Role,
        to slot: Slot
    ) {
        let previousTask = slot.loadTask
        let hadPreviousLease = slot.lease != nil
        previousTask?.cancel()
        slot.releaseTask?.cancel()
        slot.releaseTask = nil
        slot.cancelLeaseObservers()
        if let oldItemID = slot.lease?.itemID {
            slotIDByItemID.removeValue(forKey: oldItemID)
            if activeItemID == oldItemID { activeItemID = nil }
        }

        let token = UUID()
        if hadPreviousLease { slot.session.pause() }
        slot.lease = Lease(
            token: token,
            itemID: item.id,
            generation: generation,
            role: role,
            source: item.source,
            phase: .loading,
            state: slot.session.state,
            didCompleteInitialLoad: false
        )
        slotIDByItemID[item.id] = slot.id
        maximumObservedPoolOccupancy = max(maximumObservedPoolOccupancy, slotIDByItemID.count)

        let configuration = playerConfiguration
        slot.loadTask = Task { @MainActor [weak self, weak slot] in
            if let previousTask { await previousTask.value }
            guard let self, let slot, self.owns(slot, token: token) else { return }
            if hadPreviousLease { await slot.session.stopAndWait() }
            guard self.owns(slot, token: token), !Task.isCancelled else {
                self.recordStaleCompletion()
                return
            }
            await slot.session.updateConfiguration(configuration)
            guard self.owns(slot, token: token), !Task.isCancelled else {
                self.recordStaleCompletion()
                return
            }
            self.startStateObservation(for: slot, token: token)
            do {
                try await self.load(
                    item: item,
                    quality: configuration.qualityPolicy,
                    into: slot.session
                )
                guard self.owns(slot, token: token), !Task.isCancelled else {
                    self.recordStaleCompletion()
                    return
                }
                self.finishLoad(in: slot, token: token)
            } catch is CancellationError {
                if self.owns(slot, token: token) {
                    await self.releaseAfterFailedLoad(slot, token: token, message: "cancelled")
                } else {
                    self.recordStaleCompletion()
                }
            } catch {
                if self.owns(slot, token: token) {
                    await self.releaseAfterFailedLoad(
                        slot,
                        token: token,
                        message: error.localizedDescription
                    )
                } else {
                    self.recordStaleCompletion()
                }
            }
        }
    }

    private func load(
        item: FeedPlaybackItem,
        quality: HLSRewriteConfiguration.QualityPolicy,
        into session: any HLSFeedPlayerSession
    ) async throws {
        switch item.source {
        case .stream(let url, _):
            await session.load(from: url, quality: quality)
            if case .failed(let message) = session.state.status {
                throw HLSFeedEngineError.playerFailed(item.id, message)
            }
        case .compatibleClips(let clips):
            try await session.load(clips: clips)
        case .clips:
            throw HLSFeedEngineError.untypedClipSequenceRequiresCompatibility(item.id)
        }
    }

    private func finishLoad(in slot: Slot, token: UUID) {
        guard owns(slot, token: token), var lease = slot.lease else { return }
        slot.loadTask = nil
        failuresByItemID.removeValue(forKey: lease.itemID)
        lease.state = slot.session.state
        lease.didCompleteInitialLoad = true
        var failedMessage: String?
        if case .failed(let message) = lease.state.status {
            lease.phase = .failed(message)
            failedMessage = message
        } else if lease.state.status == .ready {
            lease.phase = .warm
        } else {
            lease.phase = .loading
        }
        slot.lease = lease
        slot.session.pause()
        if let failedMessage {
            failuresByItemID[lease.itemID] = .init(
                itemID: lease.itemID,
                generation: lease.generation,
                message: failedMessage
            )
            slot.releaseTask = Task { @MainActor [weak self, weak slot] in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.release(slot, token: token)
            }
        } else {
            installPlaybackEndObserver(for: slot, token: token)
        }
        if lease.itemID == targetFocusedItemID, lease.phase == .warm {
            activate(slot)
        }
        rebuildSnapshot()
    }

    private func startStateObservation(for slot: Slot, token: UUID) {
        slot.observationTask = Task { @MainActor [weak self, weak slot] in
            guard let slot else { return }
            let updates = slot.session.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled, let self, self.owns(slot, token: token) else { return }
                self.acceptPlayerState(state, from: slot, token: token)
            }
        }
    }

    private func acceptPlayerState(_ state: PlayerState, from slot: Slot, token: UUID) {
        guard owns(slot, token: token), var lease = slot.lease else { return }
        lease.state = state
        var shouldReleaseFailedSession = false
        switch state.status {
        case .ready:
            if lease.phase == .loading { lease.phase = .warm }
            if lease.didCompleteInitialLoad, slot.playbackEndObserver == nil {
                installPlaybackEndObserver(for: slot, token: token)
            }
        case .failed(let message):
            lease.phase = .failed(message)
            failuresByItemID[lease.itemID] = .init(
                itemID: lease.itemID,
                generation: lease.generation,
                message: message
            )
            shouldReleaseFailedSession = lease.didCompleteInitialLoad
        case .idle, .buffering:
            break
        }
        slot.lease = lease
        if shouldReleaseFailedSession, slot.releaseTask == nil {
            slot.releaseTask = Task { @MainActor [weak self, weak slot] in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.release(slot, token: token)
            }
        }
        if lease.itemID == targetFocusedItemID, lease.phase == .warm {
            activate(slot)
        }
        rebuildSnapshot()
    }

    private func activate(_ destination: Slot) {
        guard var destinationLease = destination.lease,
              destinationLease.phase == .warm || destinationLease.phase == .focused
        else { return }
        if activeItemID == destinationLease.itemID, destinationLease.phase == .focused {
            return
        }
        if activeItemID != destinationLease.itemID,
           let current = activeItemID.flatMap({ slot(for: $0) }),
           var currentLease = current.lease {
            current.session.pause()
            if currentLease.phase == .focused { currentLease.phase = .warm }
            current.lease = currentLease
        }
        destinationLease.phase = .focused
        destination.lease = destinationLease
        activeItemID = destinationLease.itemID
        destination.session.play()
    }

    private func scheduleRelease(of slot: Slot) {
        guard slot.releaseTask == nil, let token = slot.lease?.token else { return }
        let grace = effectivePolicy.eviction.offscreenGracePeriod
        slot.releaseTask = Task { @MainActor [weak self, weak slot] in
            if grace > 0 {
                try? await Task.sleep(for: .seconds(grace))
            }
            guard !Task.isCancelled, let self, let slot,
                  self.owns(slot, token: token),
                  let itemID = slot.lease?.itemID,
                  !self.desiredItemIDs.contains(itemID)
            else { return }
            await self.release(slot, token: token)
        }
    }

    private func release(_ slot: Slot, token: UUID) async {
        guard owns(slot, token: token), let itemID = slot.lease?.itemID else { return }
        slot.loadTask?.cancel()
        let loadTask = slot.loadTask
        slot.loadTask = nil
        slot.releaseTask = nil
        slot.cancelLeaseObservers()
        slot.session.pause()
        slotIDByItemID.removeValue(forKey: itemID)
        slot.lease = nil
        if activeItemID == itemID { activeItemID = nil }
        if let loadTask { await loadTask.value }
        await slot.session.stopAndWait()
        rebuildSnapshot()
    }

    private func releaseAfterFailedLoad(
        _ slot: Slot,
        token: UUID,
        message: String
    ) async {
        guard owns(slot, token: token), var lease = slot.lease else { return }
        lease.phase = .failed(message)
        lease.state = PlayerState(status: .failed(message))
        slot.lease = lease
        slot.loadTask = nil
        failuresByItemID[lease.itemID] = .init(
            itemID: lease.itemID,
            generation: lease.generation,
            message: message
        )
        rebuildSnapshot()
        slot.cancelLeaseObservers()
        slot.session.pause()
        slotIDByItemID.removeValue(forKey: lease.itemID)
        slot.lease = nil
        if activeItemID == lease.itemID { activeItemID = nil }
        await slot.session.stopAndWait()
        rebuildSnapshot()
    }

    private func trimPoolIfNeeded() async {
        let limit = effectivePolicy.concurrency.maximumPlayerCount
        guard slots.count > limit else { return }
        let victims = slots.reversed()
            .filter { $0.lease?.itemID != activeItemID }
            .prefix(slots.count - limit)
        for slot in victims {
            if let token = slot.lease?.token {
                await release(slot, token: token)
            }
            slots.removeAll { $0.id == slot.id }
        }
        rebuildSnapshot()
    }

    private func installPlaybackEndObserver(for slot: Slot, token: UUID) {
        if let observer = slot.playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let item = slot.session.feedPlatformPlayer?.currentItem else {
            slot.playbackEndObserver = nil
            return
        }
        slot.playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak slot] _ in
            Task { @MainActor in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.playbackEnded(in: slot, token: token)
            }
        }
    }

    private func playbackEnded(in slot: Slot, token: UUID) async {
        guard owns(slot, token: token), let lease = slot.lease,
              lease.itemID == activeItemID
        else { return }
        switch effectivePolicy.looping {
        case .disabled:
            break
        case .focusedItem:
            await slot.session.restartPlayback()
        case .orderedCollection:
            guard let index = items.firstIndex(where: { $0.id == lease.itemID }),
                  !items.isEmpty
            else { return }
            requestedDestinationItemID = items[(index + 1) % items.count].id
            rebuildSnapshot()
        }
    }

    private func controlledItemID(_ requested: FeedItemID?) throws -> FeedItemID {
        if let requested { return requested }
        if let activeItemID { return activeItemID }
        if let targetFocusedItemID { return targetFocusedItemID }
        throw HLSFeedEngineError.noFocusedItem
    }

    private func owns(_ slot: Slot, token: UUID) -> Bool {
        slot.lease?.token == token
            && slot.lease.map { slotIDByItemID[$0.itemID] == slot.id } == true
    }

    private func slot(for itemID: FeedItemID) -> Slot? {
        guard let slotID = slotIDByItemID[itemID] else { return nil }
        return slots.first { $0.id == slotID }
    }

    private func recordStaleCompletion() {
        staleCompletionCount += 1
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        let itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        let playbacks = slots.compactMap(\.lease).sorted { lhs, rhs in
            let lhsIndex = itemIndices[lhs.itemID] ?? Int.max
            let rhsIndex = itemIndices[rhs.itemID] ?? Int.max
            if lhsIndex == rhsIndex { return lhs.itemID.rawValue < rhs.itemID.rawValue }
            return lhsIndex < rhsIndex
        }.map { lease in
            HLSFeedPlayback(
                itemID: lease.itemID,
                generation: lease.generation,
                role: lease.role,
                phase: lease.phase,
                state: lease.state
            )
        }
        let activeLoads = slots.reduce(into: 0) { count, slot in
            if slot.loadTask != nil { count += 1 }
        }
        snapshot = HLSFeedEngineSnapshot(
            generation: latestCoordinatorSnapshot?.generation,
            targetFocusedItemID: targetFocusedItemID,
            activeItemID: activeItemID,
            requestedDestinationItemID: requestedDestinationItemID,
            playbacks: playbacks,
            failures: failuresByItemID.values.sorted { lhs, rhs in
                let lhsIndex = itemIndices[lhs.itemID] ?? Int.max
                let rhsIndex = itemIndices[rhs.itemID] ?? Int.max
                if lhsIndex == rhsIndex { return lhs.itemID.rawValue < rhs.itemID.rawValue }
                return lhsIndex < rhsIndex
            },
            poolOccupancy: slotIDByItemID.count,
            allocatedPlayerCount: slots.count,
            activeLoadCount: activeLoads,
            maximumObservedPoolOccupancy: maximumObservedPoolOccupancy,
            staleCompletionCount: staleCompletionCount
        )
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private static func validatedItemsByID(
        _ items: [FeedPlaybackItem]
    ) throws -> [FeedItemID: FeedPlaybackItem] {
        var result: [FeedItemID: FeedPlaybackItem] = [:]
        for item in items {
            guard !item.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeedPlanningError.emptyItemID
            }
            guard result[item.id] == nil else {
                throw FeedPlanningError.duplicateItemID(item.id)
            }
            guard !item.source.hasEmptyClipSequence else {
                throw FeedPlanningError.emptyClipSequence(item.id)
            }
            result[item.id] = item
        }
        return result
    }

    private static func playerConfiguration(
        for policy: FeedPlaybackPolicy
    ) throws -> ProxyPlayerConfiguration {
        var configuration = try policy.makeProxyPlayerConfiguration()
        if configuration.cachePolicy.enableDiskCache,
           configuration.cachePolicy.diskDirectory == nil {
            configuration.cachePolicy.diskDirectory = defaultFeedCacheDirectory()
        }
        return configuration
    }

    private static func makeSharedCache(policy: FeedPlaybackPolicy) -> HLSSegmentCache {
        let diskDirectory = policy.eviction.usesDiskCache
            ? (policy.eviction.diskDirectory ?? defaultFeedCacheDirectory())
            : nil
        return HLSSegmentCache(
            capacityBytes: policy.budget.memoryCacheBytes,
            diskDirectory: diskDirectory,
            diskCapacityBytes: policy.budget.diskCacheBytes,
            timeToLive: policy.eviction.timeToLive,
            maximumEntryCount: policy.budget.maximumCacheEntryCount
        )
    }

    private static func defaultFeedCacheDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("HLSProxyBuffer", isDirectory: true)
            .appendingPathComponent("FeedPreparation", isDirectory: true)
    }
}
