import Foundation

public actor SegmentPrefetchScheduler {
    public struct Configuration: Sendable {
        public var targetBufferSeconds: TimeInterval
        public var maxSegments: Int
        public var targetPartCount: Int

        public init(
            targetBufferSeconds: TimeInterval = 6,
            maxSegments: Int = 6,
            targetPartCount: Int = 0
        ) {
            self.targetBufferSeconds = targetBufferSeconds
            self.maxSegments = maxSegments
            self.targetPartCount = targetPartCount
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

    private enum PrefetchItem {
        case part(HLSPartialSegment)
        case segment(HLSSegment)
    }

    private var configuration: Configuration
    private let logger: Logger

    private var readySequences: Set<Int> = []
    private var readyDurations: [Int: TimeInterval] = [:]
    private var readyPartsBySequence: [Int: Set<Int>] = [:]
    private var readyPartDurations: [String: TimeInterval] = [:]
    private var bufferChangeHandler: (@Sendable (BufferState) async -> Void)?
    private var telemetryHandler: (@Sendable (Telemetry) async -> Void)?
    private var upcomingPlaylists: [MediaPlaylist] = []

    private var activePlaylist: MediaPlaylist?
    private var combinedItems: [PrefetchItem] = []
    private var nextPrefetchIndex = 0
    private var activeFetcher: (any SegmentSource)?
    private var activeCache: HLSSegmentCache?
    private var prefetchTask: Task<Void, Never>?
    private var lastConsumedSequence: Int?

    public init(configuration: Configuration = .init(), logger: Logger = DefaultLogger()) {
        self.configuration = configuration
        self.logger = logger
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public func onTelemetry(_ handler: (@Sendable (Telemetry) async -> Void)?) {
        telemetryHandler = handler
    }

    public func enqueueUpcomingPlaylists(_ playlists: [MediaPlaylist]) {
        upcomingPlaylists = playlists
        if let playlist = activePlaylist {
            combinedItems = makeCombinedItems(base: playlist)
            schedulePrefetchIfNeeded()
        }
    }

    public func start(
        playlist: MediaPlaylist,
        fetcher: any SegmentSource,
        cache: HLSSegmentCache
    ) {
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
        activeFetcher = fetcher
        activeCache = cache
        schedulePrefetchIfNeeded()
    }

    public func stop() {
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
        notifyBufferChange()
    }

    public func updatePlaylist(_ playlist: MediaPlaylist) {
        activePlaylist = playlist
        combinedItems = makeCombinedItems(base: playlist)
        schedulePrefetchIfNeeded()
    }

    public func bufferState() -> BufferState { bufferStateSnapshot() }

    public func registerReadySegment(_ segment: HLSSegment) { updateReady(segment) }

    public func registerReadyPart(_ part: HLSPartialSegment) { updateReady(part) }

    public func consume(sequence: Int) {
        let removedSequence = readySequences.remove(sequence) != nil
        let removedDuration = readyDurations.removeValue(forKey: sequence) != nil
        let removedParts = clearParts(for: sequence)

        let playheadChanged: Bool
        if let current = lastConsumedSequence {
            if sequence > current {
                lastConsumedSequence = sequence
                playheadChanged = true
            } else {
                playheadChanged = false
            }
        } else {
            lastConsumedSequence = sequence
            playheadChanged = true
        }

        if removedSequence || removedDuration || removedParts {
            logger.log(
                "consume sequence=\(sequence) ready=\(readySequences.count) depth=\(readyDurations.values.reduce(0, +) + readyPartDurations.values.reduce(0, +)) playhead=\(lastConsumedSequence.map(String.init) ?? "nil")",
                category: .scheduler
            )
            notifyBufferChange()
            schedulePrefetchIfNeeded()
        } else if playheadChanged {
            notifyBufferChange()
        }
    }

    public func consumePart(sequence: Int, partIndex: Int) {
        guard removePart(sequence: sequence, partIndex: partIndex) else { return }
        notifyBufferChange()
        schedulePrefetchIfNeeded()
    }

    public func onBufferStateChange(_ handler: (@Sendable (BufferState) async -> Void)?) {
        bufferChangeHandler = handler
    }

    private func updateReady(_ segment: HLSSegment) { markReady(sequence: segment.sequence, duration: segment.duration) }

    private func updateReady(_ part: HLSPartialSegment) {
        addPart(part)
        logger.log(
            "part sequence=\(part.parentSequence) index=\(part.partIndex) readyParts=\(readyPartsBySequence[part.parentSequence]?.count ?? 0)",
            category: .scheduler
        )
        notifyBufferChange()
        schedulePrefetchIfNeeded()
    }

    private func markReady(sequence: Int, duration: TimeInterval) {
        readySequences.insert(sequence)
        readyDurations[sequence] = duration
        logger.log(
            "segment \(sequence) ready (ready=\(readySequences.count), playhead=\(lastConsumedSequence.map(String.init) ?? "nil"))",
            category: .scheduler
        )
        notifyBufferChange()
        schedulePrefetchIfNeeded()
    }

    private func bufferStateSnapshot() -> BufferState {
        let partDepth = readyPartDurations.values.reduce(0, +)
        let segmentDepth = readyDurations.values.reduce(0, +)
        return BufferState(
            readySequences: readySequences,
            readyPartCounts: readyPartsBySequence.mapValues { $0.count },
            prefetchDepthSeconds: partDepth + segmentDepth,
            partPrefetchDepthSeconds: partDepth,
            playedThroughSequence: lastConsumedSequence
        )
    }

    private func notifyBufferChange() {
        guard let handler = bufferChangeHandler else { return }
        let state = bufferStateSnapshot()
        Task { await handler(state) }
    }

    private func reportTelemetry(scheduled: [Int], failures: Int) async {
        guard let telemetryHandler else { return }
        let telemetry = Telemetry(
            scheduledSequences: scheduled,
            readyCount: readySequences.count,
            failureCount: failures,
            readyPartCount: readyPartsBySequence.values.reduce(0) { $0 + $1.count }
        )
        await telemetryHandler(telemetry)
    }

    private func schedulePrefetchIfNeeded() {
        guard prefetchTask == nil else { return }
        guard shouldPrefetchMore(),
              nextPrefetchIndex < combinedItems.count,
              activeFetcher != nil,
              activeCache != nil else { return }

        prefetchTask = Task { [weak self] in
            await self?.runPrefetchLoop()
        }
    }

    private func runPrefetchLoop() async {
        defer { prefetchTask = nil }
        guard let fetcher = activeFetcher, let cache = activeCache else { return }

        var scheduled: [Int] = []
        var failures = 0

        while shouldPrefetchMore(),
              nextPrefetchIndex < combinedItems.count {
            if Task.isCancelled { return }
            let item = combinedItems[nextPrefetchIndex]
            let key: String
            switch item {
            case .segment(let segment):
                key = SegmentIdentity.key(for: segment)
                scheduled.append(segment.sequence)
            case .part(let part):
                key = SegmentIdentity.key(for: part)
                scheduled.append(part.parentSequence)
            }

            if await cache.get(key) != nil {
                handlePrefetchHit(for: item)
                nextPrefetchIndex += 1
                continue
            }

            do {
                let data: Data
                switch item {
                case .segment(let segment):
                    data = try await fetcher.fetchSegment(segment)
                case .part(let part):
                    data = try await fetcher.fetchPartialSegment(part)
                }
                await cache.put(data, for: key)
                handlePrefetchHit(for: item)
                nextPrefetchIndex += 1
            } catch {
                let sequence: Int
                switch item {
                case .segment(let segment):
                    sequence = segment.sequence
                case .part(let part):
                    sequence = part.parentSequence
                }
                logger.log("Prefetch failed for sequence \(sequence): \(error)", category: .scheduler)
                failures += 1
                break
            }
        }

        await reportTelemetry(scheduled: scheduled, failures: failures)
        if shouldPrefetchMore() {
            schedulePrefetchIfNeeded()
        }
    }

    private func handlePrefetchHit(for item: PrefetchItem) {
        switch item {
        case .segment(let segment):
            updateReady(segment)
        case .part(let part):
            updateReady(part)
        }
    }

    private func shouldPrefetchMore() -> Bool {
        let totalDepth = readyDurations.values.reduce(0, +) + readyPartDurations.values.reduce(0, +)
        let needsDepth = totalDepth < configuration.targetBufferSeconds
        let needsSegments = configuration.maxSegments > 0 ? readySequences.count < configuration.maxSegments : false
        let readyPartCount = readyPartsBySequence.values.reduce(0) { $0 + $1.count }
        let needsParts = configuration.targetPartCount > 0 ? readyPartCount < configuration.targetPartCount : false
        if configuration.maxSegments <= 0 && configuration.targetPartCount <= 0 && !needsDepth {
            return false
        }
        return needsDepth || needsSegments || needsParts
    }

    private func makeCombinedItems(base playlist: MediaPlaylist) -> [PrefetchItem] {
        func flatten(_ playlist: MediaPlaylist) -> [PrefetchItem] {
            playlist.segments.flatMap { segment -> [PrefetchItem] in
                let partItems = segment.parts.map { PrefetchItem.part($0) }
                return partItems + [.segment(segment)]
            }
        }

        return flatten(playlist) + upcomingPlaylists.flatMap { flatten($0) }
    }

    private func addPart(_ part: HLSPartialSegment) {
        var set = readyPartsBySequence[part.parentSequence] ?? []
        if set.insert(part.partIndex).inserted {
            readyPartsBySequence[part.parentSequence] = set
            let key = SegmentIdentity.key(forPartSequence: part.parentSequence, partIndex: part.partIndex)
            readyPartDurations[key] = part.duration
        }
    }

    private func clearParts(for sequence: Int) -> Bool {
        guard let parts = readyPartsBySequence.removeValue(forKey: sequence) else { return false }
        var removed = false
        for index in parts {
            let key = SegmentIdentity.key(forPartSequence: sequence, partIndex: index)
            if readyPartDurations.removeValue(forKey: key) != nil {
                removed = true
            }
        }
        return removed
    }

    @discardableResult
    private func removePart(sequence: Int, partIndex: Int) -> Bool {
        guard var set = readyPartsBySequence[sequence], set.contains(partIndex) else { return false }
        set.remove(partIndex)
        if set.isEmpty {
            readyPartsBySequence.removeValue(forKey: sequence)
        } else {
            readyPartsBySequence[sequence] = set
        }
        let key = SegmentIdentity.key(forPartSequence: sequence, partIndex: partIndex)
        readyPartDurations.removeValue(forKey: key)
        return true
    }
}
