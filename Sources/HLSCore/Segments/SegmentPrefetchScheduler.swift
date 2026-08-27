import Foundation

public actor SegmentPrefetchScheduler {
    public struct Configuration: Sendable {
        public var targetBufferSeconds: TimeInterval
        public var maxSegments: Int
        public var targetPartCount: Int
        public var maxConcurrentFetches: Int
        public var maximumRetryCount: Int
        public var retryBaseDelay: TimeInterval

        public init(
            targetBufferSeconds: TimeInterval = 6,
            maxSegments: Int = 6,
            targetPartCount: Int = 0,
            maxConcurrentFetches: Int = 3,
            maximumRetryCount: Int = 3,
            retryBaseDelay: TimeInterval = 0.2
        ) {
            self.targetBufferSeconds = max(0, targetBufferSeconds)
            self.maxSegments = max(0, maxSegments)
            self.targetPartCount = max(0, targetPartCount)
            self.maxConcurrentFetches = max(1, maxConcurrentFetches)
            self.maximumRetryCount = max(0, maximumRetryCount)
            self.retryBaseDelay = max(0, retryBaseDelay)
        }
    }

    public struct Telemetry: Sendable {
        public let scheduledSequences: [Int]
        public let readyCount: Int
        public let failureCount: Int
        public let readyPartCount: Int

        public init(
            scheduledSequences: [Int],
            readyCount: Int,
            failureCount: Int,
            readyPartCount: Int
        ) {
            self.scheduledSequences = scheduledSequences
            self.readyCount = readyCount
            self.failureCount = failureCount
            self.readyPartCount = readyPartCount
        }
    }

    private enum PrefetchItem: Sendable {
        case part(HLSPartialSegment)
        case segment(HLSSegment)

        var sequence: Int {
            switch self {
            case .part(let part): part.parentSequence
            case .segment(let segment): segment.sequence
            }
        }

        var key: String {
            switch self {
            case .part(let part): SegmentIdentity.key(for: part)
            case .segment(let segment): SegmentIdentity.key(for: segment)
            }
        }
    }

    private struct PrefetchResult: Sendable {
        let item: PrefetchItem
        let succeeded: Bool
        let errorDescription: String?
    }

    private var configuration: Configuration
    private let logger: Logger
    private var readySequences: Set<Int> = []
    private var readyDurations: [Int: TimeInterval] = [:]
    private var readyPartsBySequence: [Int: Set<Int>] = [:]
    private var readyPartDurations: [String: TimeInterval] = [:]
    private var telemetryHandler: (@Sendable (Telemetry) async -> Void)?
    private var upcomingPlaylists: [MediaPlaylist] = []
    private var activePlaylist: MediaPlaylist?
    private var combinedItems: [PrefetchItem] = []
    private var nextPrefetchIndex = 0
    private var activeFetcher: (any SegmentSource)?
    private var activeCache: HLSSegmentCache?
    private var prefetchTask: Task<Void, Never>?
    private var callbackTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var consecutiveFailureCycles = 0
    private var lastConsumedSequence: Int?
    private var stateContinuations: [UUID: AsyncStream<BufferState>.Continuation] = [:]

    public init(configuration: Configuration = .init(), logger: Logger = DefaultLogger()) {
        self.configuration = configuration
        self.logger = logger
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        schedulePrefetchIfNeeded()
    }

    public func onTelemetry(_ handler: (@Sendable (Telemetry) async -> Void)?) {
        telemetryHandler = handler
    }

    /// Ordered, bounded state updates suitable for Observation or feed coordination.
    public func states() -> AsyncStream<BufferState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateContinuations[id] = continuation
            continuation.yield(bufferStateSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    public func enqueueUpcomingPlaylists(_ playlists: [MediaPlaylist]) {
        upcomingPlaylists = playlists
        if let playlist = activePlaylist {
            generation &+= 1
            prefetchTask?.cancel()
            prefetchTask = nil
            combinedItems = makeCombinedItems(base: playlist)
            reconcilePrefetchIndex()
            schedulePrefetchIfNeeded()
        }
    }

    public func start(
        playlist: MediaPlaylist,
        fetcher: any SegmentSource,
        cache: HLSSegmentCache
    ) {
        generation &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        activePlaylist = playlist
        combinedItems = makeCombinedItems(base: playlist)
        nextPrefetchIndex = 0
        readySequences.removeAll()
        readyDurations.removeAll()
        readyPartsBySequence.removeAll()
        readyPartDurations.removeAll()
        lastConsumedSequence = nil
        consecutiveFailureCycles = 0
        activeFetcher = fetcher
        activeCache = cache
        publishState()
        schedulePrefetchIfNeeded()
    }

    public func stop() {
        generation &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        activePlaylist = nil
        combinedItems.removeAll()
        nextPrefetchIndex = 0
        activeFetcher = nil
        activeCache = nil
        readySequences.removeAll()
        readyDurations.removeAll()
        readyPartsBySequence.removeAll()
        readyPartDurations.removeAll()
        lastConsumedSequence = nil
        consecutiveFailureCycles = 0
        publishState()
    }

    public func updatePlaylist(_ playlist: MediaPlaylist) {
        generation &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        activePlaylist = playlist
        combinedItems = makeCombinedItems(base: playlist)
        let validSequences = Set(playlist.segments.map(\.sequence))
        readySequences.formIntersection(validSequences)
        readyDurations = readyDurations.filter { validSequences.contains($0.key) }
        readyPartsBySequence = readyPartsBySequence.filter { validSequences.contains($0.key) || $0.key >= playlist.mediaSequence }
        let validPartKeys = Set(readyPartsBySequence.flatMap { sequence, indices in
            indices.map { partDurationKey(sequence: sequence, partIndex: $0) }
        })
        readyPartDurations = readyPartDurations.filter { validPartKeys.contains($0.key) }
        reconcilePrefetchIndex()
        publishState()
        schedulePrefetchIfNeeded()
    }

    public func bufferState() -> BufferState { bufferStateSnapshot() }

    public func registerReadySegment(_ segment: HLSSegment) { updateReady(segment) }

    public func registerReadyPart(_ part: HLSPartialSegment) { updateReady(part) }

    public func consume(sequence: Int) {
        let sequencesToConsume = Set(readySequences.filter { $0 <= sequence })
            .union(readyDurations.keys.filter { $0 <= sequence })
            .union(readyPartsBySequence.keys.filter { $0 <= sequence })
        var removed = false
        for consumed in sequencesToConsume {
            removed = readySequences.remove(consumed) != nil || removed
            removed = readyDurations.removeValue(forKey: consumed) != nil || removed
            removed = clearParts(for: consumed) || removed
        }
        let playheadChanged: Bool
        if let current = lastConsumedSequence {
            playheadChanged = sequence > current
            if playheadChanged { lastConsumedSequence = sequence }
        } else {
            lastConsumedSequence = sequence
            playheadChanged = true
        }

        if removed || playheadChanged {
            publishState()
            schedulePrefetchIfNeeded()
        }
    }

    public func consumePart(sequence: Int, partIndex: Int) {
        guard removePart(sequence: sequence, partIndex: partIndex) else { return }
        publishState()
        schedulePrefetchIfNeeded()
    }

    public func onBufferStateChange(_ handler: (@Sendable (BufferState) async -> Void)?) {
        callbackTask?.cancel()
        callbackTask = nil
        guard let handler else { return }
        let stream = states()
        callbackTask = Task {
            for await state in stream {
                guard !Task.isCancelled else { return }
                await handler(state)
            }
        }
    }

    private func updateReady(_ segment: HLSSegment) {
        readySequences.insert(segment.sequence)
        readyDurations[segment.sequence] = segment.duration
        publishState()
    }

    private func updateReady(_ part: HLSPartialSegment) {
        var set = readyPartsBySequence[part.parentSequence] ?? []
        if set.insert(part.partIndex).inserted {
            readyPartsBySequence[part.parentSequence] = set
            readyPartDurations[partDurationKey(sequence: part.parentSequence, partIndex: part.partIndex)] = part.duration
            publishState()
        }
    }

    private func bufferStateSnapshot() -> BufferState {
        let partDepth = readyPartDurations.values.reduce(0, +)
        let segmentDepth = readyDurations.values.reduce(0, +)
        return BufferState(
            readySequences: readySequences,
            readyPartCounts: readyPartsBySequence.mapValues(\.count),
            prefetchDepthSeconds: partDepth + segmentDepth,
            partPrefetchDepthSeconds: partDepth,
            playedThroughSequence: lastConsumedSequence
        )
    }

    private func publishState() {
        let snapshot = bufferStateSnapshot()
        for continuation in stateContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func reportTelemetry(scheduled: [Int], failures: Int) async {
        guard let telemetryHandler else { return }
        await telemetryHandler(Telemetry(
            scheduledSequences: scheduled,
            readyCount: readySequences.count,
            failureCount: failures,
            readyPartCount: readyPartsBySequence.values.reduce(0) { $0 + $1.count }
        ))
    }

    private func schedulePrefetchIfNeeded() {
        guard prefetchTask == nil,
              shouldPrefetchMore(),
              nextPrefetchIndex < combinedItems.count,
              activeFetcher != nil,
              activeCache != nil else { return }
        let taskGeneration = generation
        prefetchTask = Task { [weak self] in
            await self?.runPrefetchLoop(generation: taskGeneration)
        }
    }

    private func runPrefetchLoop(generation taskGeneration: UInt64) async {
        guard taskGeneration == generation,
              let fetcher = activeFetcher,
              let cache = activeCache else { return }
        var scheduled: [Int] = []
        var failures = 0

        while !Task.isCancelled, taskGeneration == generation, shouldPrefetchMore() {
            let batch = nextBatch()
            guard !batch.isEmpty else { break }
            scheduled.append(contentsOf: batch.map(\.sequence))
            let retryCount = configuration.maximumRetryCount
            let retryDelay = configuration.retryBaseDelay
            let results = await withTaskGroup(of: PrefetchResult.self, returning: [PrefetchResult].self) { group in
                for item in batch {
                    group.addTask {
                        await Self.prefetch(
                            item,
                            fetcher: fetcher,
                            cache: cache,
                            maximumRetryCount: retryCount,
                            retryBaseDelay: retryDelay
                        )
                    }
                }
                var values: [PrefetchResult] = []
                for await result in group { values.append(result) }
                return values
            }

            for result in results {
                guard taskGeneration == generation else { break }
                if result.succeeded {
                    handlePrefetchHit(for: result.item)
                } else {
                    failures += 1
                    logger.log(
                        "Prefetch failed for sequence \(result.item.sequence): \(result.errorDescription ?? "unknown error")",
                        category: .scheduler
                    )
                }
            }
            if results.contains(where: { !$0.succeeded }) {
                let failedKeys = Set(results.filter { !$0.succeeded }.map { $0.item.key })
                if let firstFailure = combinedItems.firstIndex(where: { failedKeys.contains($0.key) }) {
                    nextPrefetchIndex = min(nextPrefetchIndex, firstFailure)
                }
                break
            }
        }

        await reportTelemetry(scheduled: scheduled, failures: failures)
        completePrefetchTask(generation: taskGeneration, shouldDelayRetry: failures > 0)
    }

    private nonisolated static func prefetch(
        _ item: PrefetchItem,
        fetcher: any SegmentSource,
        cache: HLSSegmentCache,
        maximumRetryCount: Int,
        retryBaseDelay: TimeInterval
    ) async -> PrefetchResult {
        if await cache.get(item.key) != nil {
            return PrefetchResult(item: item, succeeded: true, errorDescription: nil)
        }
        var attempt = 0
        while !Task.isCancelled {
            do {
                let data: Data
                switch item {
                case .segment(let segment): data = try await fetcher.fetchSegment(segment)
                case .part(let part): data = try await fetcher.fetchPartialSegment(part)
                }
                await cache.put(data, for: item.key)
                return PrefetchResult(item: item, succeeded: true, errorDescription: nil)
            } catch is CancellationError {
                return PrefetchResult(item: item, succeeded: false, errorDescription: "cancelled")
            } catch {
                guard attempt < maximumRetryCount else {
                    return PrefetchResult(item: item, succeeded: false, errorDescription: String(describing: error))
                }
                attempt += 1
                let delay = retryBaseDelay * pow(2, Double(attempt - 1))
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return PrefetchResult(item: item, succeeded: false, errorDescription: "cancelled")
                }
            }
        }
        return PrefetchResult(item: item, succeeded: false, errorDescription: "cancelled")
    }

    private func nextBatch() -> [PrefetchItem] {
        var items: [PrefetchItem] = []
        let segmentAllowance = configuration.maxSegments > 0
            ? max(1, configuration.maxSegments - readySequences.count)
            : configuration.maxConcurrentFetches
        let limit = min(configuration.maxConcurrentFetches, segmentAllowance)
        while items.count < limit, nextPrefetchIndex < combinedItems.count {
            let item = combinedItems[nextPrefetchIndex]
            nextPrefetchIndex += 1
            if !isReady(item) { items.append(item) }
        }
        return items
    }

    private func completePrefetchTask(generation taskGeneration: UInt64, shouldDelayRetry: Bool) {
        guard taskGeneration == generation else { return }
        prefetchTask = nil
        guard shouldPrefetchMore(), nextPrefetchIndex < combinedItems.count else {
            consecutiveFailureCycles = 0
            return
        }
        if shouldDelayRetry {
            let exponent = min(consecutiveFailureCycles, 5)
            consecutiveFailureCycles += 1
            let base = max(0.5, configuration.retryBaseDelay)
            let delay = min(8, base * pow(2, Double(exponent)))
            prefetchTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                await self?.resumePrefetch(after: taskGeneration)
            }
        } else {
            consecutiveFailureCycles = 0
            schedulePrefetchIfNeeded()
        }
    }

    private func resumePrefetch(after taskGeneration: UInt64) {
        guard taskGeneration == generation else { return }
        prefetchTask = nil
        schedulePrefetchIfNeeded()
    }

    private func handlePrefetchHit(for item: PrefetchItem) {
        switch item {
        case .segment(let segment): updateReady(segment)
        case .part(let part): updateReady(part)
        }
    }

    private func isReady(_ item: PrefetchItem) -> Bool {
        switch item {
        case .segment(let segment): readySequences.contains(segment.sequence)
        case .part(let part): readyPartsBySequence[part.parentSequence]?.contains(part.partIndex) == true
        }
    }

    private func shouldPrefetchMore() -> Bool {
        let totalDepth = readyDurations.values.reduce(0, +) + readyPartDurations.values.reduce(0, +)
        let needsDepth = totalDepth < configuration.targetBufferSeconds
        let needsSegments = configuration.maxSegments > 0 && readySequences.count < configuration.maxSegments
        let readyPartCount = readyPartsBySequence.values.reduce(0) { $0 + $1.count }
        let needsParts = configuration.targetPartCount > 0 && readyPartCount < configuration.targetPartCount
        return needsDepth || needsSegments || needsParts
    }

    private func makeCombinedItems(base playlist: MediaPlaylist) -> [PrefetchItem] {
        func flatten(_ playlist: MediaPlaylist) -> [PrefetchItem] {
            let complete = playlist.segments.flatMap { segment -> [PrefetchItem] in
                segment.parts.map(PrefetchItem.part) + [.segment(segment)]
            }
            return complete + playlist.trailingParts.map(PrefetchItem.part)
        }
        return flatten(playlist) + upcomingPlaylists.flatMap(flatten)
    }

    private func reconcilePrefetchIndex() {
        nextPrefetchIndex = combinedItems.firstIndex(where: { !isReady($0) }) ?? combinedItems.endIndex
    }

    private func clearParts(for sequence: Int) -> Bool {
        guard let parts = readyPartsBySequence.removeValue(forKey: sequence) else { return false }
        var removed = false
        for index in parts {
            if readyPartDurations.removeValue(forKey: partDurationKey(sequence: sequence, partIndex: index)) != nil {
                removed = true
            }
        }
        return removed
    }

    @discardableResult
    private func removePart(sequence: Int, partIndex: Int) -> Bool {
        guard var set = readyPartsBySequence[sequence], set.remove(partIndex) != nil else { return false }
        if set.isEmpty {
            readyPartsBySequence.removeValue(forKey: sequence)
        } else {
            readyPartsBySequence[sequence] = set
        }
        readyPartDurations.removeValue(forKey: partDurationKey(sequence: sequence, partIndex: partIndex))
        return true
    }

    private func partDurationKey(sequence: Int, partIndex: Int) -> String {
        "\(sequence):\(partIndex)"
    }
}
