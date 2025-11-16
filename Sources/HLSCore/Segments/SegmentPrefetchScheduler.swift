import Foundation

public actor SegmentPrefetchScheduler {
    public struct Configuration: Sendable {
        public var targetBufferSeconds: TimeInterval
        public var maxSegments: Int

        public init(targetBufferSeconds: TimeInterval = 6, maxSegments: Int = 6) {
            self.targetBufferSeconds = targetBufferSeconds
            self.maxSegments = maxSegments
        }
    }

    public struct Telemetry: Sendable {
        public let scheduledSequences: [Int]
        public let readyCount: Int
        public let failureCount: Int
    }

    private var configuration: Configuration
    private let logger: Logger

    private var readySequences: Set<Int> = []
    private var readyDurations: [Int: TimeInterval] = [:]
    private var bufferChangeHandler: (@Sendable (BufferState) async -> Void)?
    private var telemetryHandler: (@Sendable (Telemetry) async -> Void)?
    private var upcomingPlaylists: [MediaPlaylist] = []

    private var activePlaylist: MediaPlaylist?
    private var combinedSegments: [HLSSegment] = []
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
            combinedSegments = makeCombinedSegments(base: playlist)
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
        combinedSegments = makeCombinedSegments(base: playlist)
        nextPrefetchIndex = 0
        readySequences.removeAll()
        readyDurations.removeAll()
        lastConsumedSequence = nil
        activeFetcher = fetcher
        activeCache = cache
        schedulePrefetchIfNeeded()
    }

    public func stop() {
        prefetchTask?.cancel()
        prefetchTask = nil
        activePlaylist = nil
        combinedSegments.removeAll()
        nextPrefetchIndex = 0
        activeFetcher = nil
        activeCache = nil
        readySequences.removeAll()
        readyDurations.removeAll()
        lastConsumedSequence = nil
        notifyBufferChange()
    }

    public func updatePlaylist(_ playlist: MediaPlaylist) {
        activePlaylist = playlist
        combinedSegments = makeCombinedSegments(base: playlist)
        schedulePrefetchIfNeeded()
    }

    public func bufferState() -> BufferState { bufferStateSnapshot() }

    public func registerReadySegment(_ segment: HLSSegment) { updateReady(segment) }

    public func consume(sequence: Int) {
        let removedSequence = readySequences.remove(sequence) != nil
        let removedDuration = readyDurations.removeValue(forKey: sequence) != nil

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

        if removedSequence || removedDuration {
            logger.log(
                "consume sequence=\(sequence) ready=\(readySequences.count) depth=\(readyDurations.values.reduce(0, +)) playhead=\(lastConsumedSequence.map(String.init) ?? "nil")",
                category: .scheduler
            )
            notifyBufferChange()
            schedulePrefetchIfNeeded()
        } else if playheadChanged {
            notifyBufferChange()
        }
    }

    public func onBufferStateChange(_ handler: (@Sendable (BufferState) async -> Void)?) {
        bufferChangeHandler = handler
    }

    private func updateReady(_ segment: HLSSegment) { markReady(sequence: segment.sequence, duration: segment.duration) }

    private func markReady(sequence: Int, duration: TimeInterval) {
        readySequences.insert(sequence)
        readyDurations[sequence] = duration
        logger.log("segment \(sequence) ready (ready=\(readySequences.count), playhead=\(lastConsumedSequence.map(String.init) ?? "nil"))", category: .scheduler)
        notifyBufferChange()
        schedulePrefetchIfNeeded()
    }

    private func bufferStateSnapshot() -> BufferState {
        BufferState(
            readySequences: readySequences,
            prefetchDepthSeconds: readyDurations.values.reduce(0, +),
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
            failureCount: failures
        )
        await telemetryHandler(telemetry)
    }

    private func schedulePrefetchIfNeeded() {
        guard prefetchTask == nil else { return }
        guard shouldPrefetchMore(),
              nextPrefetchIndex < combinedSegments.count,
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
              nextPrefetchIndex < combinedSegments.count {
            if Task.isCancelled { return }
            let segment = combinedSegments[nextPrefetchIndex]
            let key = SegmentIdentity.key(for: segment)
            scheduled.append(segment.sequence)

            if await cache.get(key) != nil {
                updateReady(segment)
                nextPrefetchIndex += 1
                continue
            }

            do {
                let data = try await fetcher.fetchSegment(segment)
                await cache.put(data, for: key)
                updateReady(segment)
                nextPrefetchIndex += 1
            } catch {
                logger.log("Prefetch failed for \(segment.sequence): \(error)", category: .scheduler)
                failures += 1
                break
            }
        }

        await reportTelemetry(scheduled: scheduled, failures: failures)
        if shouldPrefetchMore() {
            schedulePrefetchIfNeeded()
        }
    }

    private func shouldPrefetchMore() -> Bool {
        if configuration.maxSegments <= 0 {
            return false
        }
        let depth = readyDurations.values.reduce(0, +)
        let readyCount = readySequences.count
        return depth < configuration.targetBufferSeconds || readyCount < configuration.maxSegments
    }

    private func makeCombinedSegments(base playlist: MediaPlaylist) -> [HLSSegment] {
        playlist.segments + upcomingPlaylists.flatMap { $0.segments }
    }
}
