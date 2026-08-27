import Foundation

/// A typed analytics value accepted by the delivery pipeline.
///
/// The record identifier is the idempotency key. Sinks must deduplicate by
/// that identifier because a timeout or process interruption can cause the
/// same record to be delivered more than once.
public enum PlaybackAnalyticsRecord: Equatable, Codable, Sendable {
    case event(PlaybackAnalytics.Event)
    case summary(PlaybackAnalytics.Summary)

    public var idempotencyID: PlaybackAnalytics.RecordID {
        switch self {
        case .event(let event): event.recordID
        case .summary(let summary): summary.recordID
        }
    }

    public var priority: PlaybackAnalytics.Priority {
        switch self {
        case .event(let event): event.priority
        case .summary: .critical
        }
    }

    private enum Kind: String, Codable {
        case event
        case summary
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case event
        case summary
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .event:
            self = .event(try container.decode(PlaybackAnalytics.Event.self, forKey: .event))
        case .summary:
            self = .summary(try container.decode(PlaybackAnalytics.Summary.self, forKey: .summary))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode(Kind.event, forKey: .kind)
            try container.encode(event, forKey: .event)
        case .summary(let summary):
            try container.encode(Kind.summary, forKey: .kind)
            try container.encode(summary, forKey: .summary)
        }
    }
}

/// One bounded unit delivered to a vendor-neutral sink.
public struct PlaybackAnalyticsBatch: Equatable, Codable, Sendable {
    public let records: [PlaybackAnalyticsRecord]

    public var idempotencyIDs: [PlaybackAnalytics.RecordID] {
        records.map(\.idempotencyID)
    }

    public init(records: [PlaybackAnalyticsRecord]) {
        self.records = records
    }
}

/// The only operation required of an analytics destination.
///
/// Implementations must honor task cancellation and must not retain batches
/// after `send` returns. Authentication belongs to the sink configuration,
/// never to a record or batch.
public protocol PlaybackAnalyticsSink: Sendable {
    func send(_ batch: PlaybackAnalyticsBatch) async throws
}

/// Tells the delivery actor whether retrying a sink failure can make progress.
public enum PlaybackAnalyticsRetryDisposition: Equatable, Sendable {
    case retryable
    case permanent
}

/// Optional error contract for sinks that can classify failures.
///
/// Unknown errors remain retryable for backward compatibility. Permanent
/// failures skip delivery backoff and move directly to configured spool/drop
/// behavior.
public protocol PlaybackAnalyticsRetryClassifyingError: Error, Sendable {
    var retryDisposition: PlaybackAnalyticsRetryDisposition { get }
}

/// Playback-independent, bounded delivery for typed analytics records.
///
/// Calls to `record` only perform actor-isolated memory admission. Sink and
/// optional disk-spool work is performed by the single delivery worker, and
/// disk operations leave the actor while they execute.
public actor PlaybackAnalyticsDelivery {
    public struct Configuration: Equatable, Sendable {
        public struct RetryPolicy: Equatable, Sendable {
            public let maximumAttempts: Int
            public let initialDelay: Duration
            public let multiplier: Double
            public let maximumDelay: Duration

            public init(
                maximumAttempts: Int = 3,
                initialDelay: Duration = .milliseconds(250),
                multiplier: Double = 2,
                maximumDelay: Duration = .seconds(8)
            ) {
                self.maximumAttempts = min(max(1, maximumAttempts), 8)
                self.initialDelay = max(.zero, initialDelay)
                self.multiplier = min(max(1, multiplier.isFinite ? multiplier : 1), 8)
                self.maximumDelay = max(self.initialDelay, maximumDelay)
            }

            fileprivate func delay(afterFailedAttempt attempt: Int) -> Duration {
                let exponent = min(max(0, attempt - 1), 16)
                return min(maximumDelay, initialDelay * pow(multiplier, Double(exponent)))
            }
        }

        public struct DiskSpool: Equatable, Sendable {
            public let directory: URL
            public let maximumBytes: Int
            public let maximumRecordCount: Int

            public init(
                directory: URL,
                maximumBytes: Int = 4 * 1_024 * 1_024,
                maximumRecordCount: Int = 2_048
            ) {
                self.directory = directory
                self.maximumBytes = min(max(1_024, maximumBytes), 64 * 1_024 * 1_024)
                self.maximumRecordCount = min(max(1, maximumRecordCount), 16_384)
            }
        }

        /// Routine events use deterministic record-ID sampling. Important
        /// events and summaries are never sampled out.
        public let routineSamplingRate: Double
        public let memoryBudgetBytes: Int
        public let maximumQueuedRecordCount: Int
        public let maximumBatchBytes: Int
        public let maximumBatchRecordCount: Int
        public let flushInterval: Duration
        public let shutdownFlushTimeout: Duration
        public let retryPolicy: RetryPolicy
        public let diskSpool: DiskSpool?

        public init(
            routineSamplingRate: Double = 1,
            memoryBudgetBytes: Int = 512 * 1_024,
            maximumQueuedRecordCount: Int = 512,
            maximumBatchBytes: Int = 64 * 1_024,
            maximumBatchRecordCount: Int = 64,
            flushInterval: Duration = .seconds(5),
            shutdownFlushTimeout: Duration = .seconds(2),
            retryPolicy: RetryPolicy = .init(),
            diskSpool: DiskSpool? = nil
        ) {
            let memoryBudgetBytes = min(max(1_024, memoryBudgetBytes), 16 * 1_024 * 1_024)
            self.routineSamplingRate = min(
                max(0, routineSamplingRate.isFinite ? routineSamplingRate : 0),
                1
            )
            self.memoryBudgetBytes = memoryBudgetBytes
            self.maximumQueuedRecordCount = min(max(1, maximumQueuedRecordCount), 16_384)
            self.maximumBatchBytes = min(max(1_024, maximumBatchBytes), memoryBudgetBytes)
            self.maximumBatchRecordCount = min(max(1, maximumBatchRecordCount), 1_024)
            self.flushInterval = max(.zero, flushInterval)
            self.shutdownFlushTimeout = max(.zero, shutdownFlushTimeout)
            self.retryPolicy = retryPolicy
            self.diskSpool = diskSpool
        }
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let isAcceptingRecords: Bool
        public let isDelivering: Bool
        public let queuedRecordCount: Int
        public let queuedBytes: Int
        public let maximumQueuedRecordCount: Int
        public let memoryBudgetBytes: Int
        public let maximumObservedQueuedRecordCount: Int
        public let maximumObservedQueuedBytes: Int
        public let spooledRecordCount: Int
        public let spooledBytes: Int
        public let maximumSpooledRecordCount: Int
        public let maximumSpoolBytes: Int
        public let deliveredRecordCount: UInt64
        public let deliveredBatchCount: UInt64
        public let sampledOutRecordCount: UInt64
        public let droppedRoutineRecordCount: UInt64
        public let droppedImportantRecordCount: UInt64
        public let droppedCriticalRecordCount: UInt64
        public let retryCount: UInt64
        public let exportFailureCount: UInt64
        public let spoolFailureCount: UInt64
        public let activeTaskCount: Int
        public let taskLimit: Int
        public let maximumObservedTaskCount: Int
    }

    struct Clock: Sendable {
        static let continuous = Self { duration in
            guard duration > .zero else {
                try Task.checkCancellation()
                return
            }
            try await ContinuousClock().sleep(for: duration)
        }

        private let sleeper: @Sendable (Duration) async throws -> Void

        init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
            sleeper = sleep
        }

        func sleep(for duration: Duration) async throws {
            try await sleeper(duration)
        }
    }

    public nonisolated let snapshots: AsyncStream<Snapshot>

    public var snapshot: Snapshot {
        snapshotValue()
    }

    private struct QueuedRecord: Sendable {
        let record: PlaybackAnalyticsRecord
        let estimatedBytes: Int
    }

    private struct SpoolFile: Sendable {
        let url: URL
        let byteCount: Int
        let priority: PlaybackAnalytics.Priority
        let modifiedAt: Date
    }

    private struct SpoolState: Sendable {
        let files: [SpoolFile]

        var byteCount: Int {
            files.reduce(into: 0) { $0 = Self.saturatingAdd($0, $1.byteCount) }
        }

        static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (result, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : result
        }
    }

    private struct SpoolRead: Sendable {
        let records: [(file: SpoolFile, record: PlaybackAnalyticsRecord)]
        let state: SpoolState
        let corruptRecordCount: Int
    }

    private struct SpoolWriteResult: Sendable {
        let state: SpoolState
        let droppedPriorities: [PlaybackAnalytics.Priority]
        let failureCount: Int
    }

    private let sink: any PlaybackAnalyticsSink
    private let configuration: Configuration
    private let clock: Clock
    private let snapshotContinuation: AsyncStream<Snapshot>.Continuation
    private var queue: [QueuedRecord] = []
    private var queuedBytes = 0
    private var maximumObservedQueuedRecordCount = 0
    private var maximumObservedQueuedBytes = 0
    private var spooledRecordCount = 0
    private var spooledBytes = 0
    private var deliveredRecordCount: UInt64 = 0
    private var deliveredBatchCount: UInt64 = 0
    private var sampledOutRecordCount: UInt64 = 0
    private var droppedRoutineRecordCount: UInt64 = 0
    private var droppedImportantRecordCount: UInt64 = 0
    private var droppedCriticalRecordCount: UInt64 = 0
    private var retryCount: UInt64 = 0
    private var exportFailureCount: UInt64 = 0
    private var spoolFailureCount: UInt64 = 0
    private var activeTaskCount = 0
    private var maximumObservedTaskCount = 0
    private var workerTask: Task<Void, Never>?
    private var workerToken: UUID?
    private var isAcceptingRecords = true
    private var isDelivering = false
    private var didInspectSpool = false

    public init(
        sink: any PlaybackAnalyticsSink,
        configuration: Configuration = .init()
    ) {
        self.sink = sink
        self.configuration = configuration
        clock = .continuous
        let pair = AsyncStream.makeStream(
            of: Snapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshots = pair.stream
        snapshotContinuation = pair.continuation
    }

    init(
        sink: any PlaybackAnalyticsSink,
        configuration: Configuration,
        clock: Clock
    ) {
        self.sink = sink
        self.configuration = configuration
        self.clock = clock
        let pair = AsyncStream.makeStream(
            of: Snapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshots = pair.stream
        snapshotContinuation = pair.continuation
    }

    deinit {
        workerTask?.cancel()
        snapshotContinuation.finish()
    }

    /// Admits one event without performing or awaiting sink or disk I/O.
    public func record(_ event: PlaybackAnalytics.Event) {
        record(.event(event))
    }

    /// Admits one terminal summary at critical priority without performing or
    /// awaiting sink or disk I/O.
    public func record(_ summary: PlaybackAnalytics.Summary) {
        record(.summary(summary))
    }

    /// Immediately makes a best-effort delivery pass. Records that exhaust
    /// retries move to the optional bounded disk spool.
    public func flush() async {
        await replaceScheduledWorkerWithImmediatePass()
    }

    /// Stops admission and makes one deadline-bounded, best-effort pass.
    /// Returns `true` only when both memory and disk queues are empty.
    @discardableResult
    public func shutdown(flushTimeout: Duration? = nil) async -> Bool {
        guard isAcceptingRecords || workerTask != nil else {
            return queue.isEmpty && spooledRecordCount == 0
        }
        isAcceptingRecords = false
        publishSnapshot()

        if let workerTask {
            workerTask.cancel()
            await workerTask.value
        }

        let timeout = max(.zero, flushTimeout ?? configuration.shutdownFlushTimeout)
        let token = UUID()
        workerToken = token
        let flushTask = Task { [weak self] in
            _ = await self?.performDeliveryPass(token: token, reschedule: false)
        }
        workerTask = flushTask
        taskStarted()

        let clock = self.clock
        let watchdog = Task {
            do {
                try await clock.sleep(for: timeout)
                flushTask.cancel()
            } catch {
                // The delivery pass completed and cancelled its watchdog.
            }
        }
        taskStarted()
        await flushTask.value
        watchdog.cancel()
        await watchdog.value
        taskEnded()

        if !queue.isEmpty {
            let records = queue.map(\.record)
            queue.removeAll(keepingCapacity: false)
            queuedBytes = 0
            await spoolOrDrop(records)
        }
        workerTask = nil
        workerToken = nil
        snapshotContinuation.finish()
        publishSnapshot()
        return queue.isEmpty && spooledRecordCount == 0
    }

    private func record(_ record: PlaybackAnalyticsRecord) {
        guard isAcceptingRecords else {
            incrementDrop(for: record.priority)
            publishSnapshot()
            return
        }
        if record.priority == .routine,
           !Self.isSampled(record.idempotencyID, rate: configuration.routineSamplingRate) {
            sampledOutRecordCount = Self.saturatingAdd(sampledOutRecordCount, 1)
            publishSnapshot()
            return
        }

        let estimatedBytes = Self.estimatedMemoryBytes(for: record)
        guard estimatedBytes <= configuration.memoryBudgetBytes else {
            incrementDrop(for: record.priority)
            publishSnapshot()
            return
        }

        while queue.count >= configuration.maximumQueuedRecordCount
            || queuedBytes > configuration.memoryBudgetBytes - estimatedBytes {
            guard let victimIndex = evictionIndex(forIncoming: record.priority) else {
                incrementDrop(for: record.priority)
                publishSnapshot()
                return
            }
            let victim = queue.remove(at: victimIndex)
            queuedBytes -= victim.estimatedBytes
            incrementDrop(for: victim.record.priority)
        }

        queue.append(.init(record: record, estimatedBytes: estimatedBytes))
        queuedBytes += estimatedBytes
        maximumObservedQueuedRecordCount = max(maximumObservedQueuedRecordCount, queue.count)
        maximumObservedQueuedBytes = max(maximumObservedQueuedBytes, queuedBytes)
        scheduleWorkerIfNeeded()
        publishSnapshot()
    }

    private func evictionIndex(forIncoming priority: PlaybackAnalytics.Priority) -> Int? {
        let incomingRank = Self.rank(priority)
        let lowestRank = queue.lazy.map { Self.rank($0.record.priority) }.min()
        guard let lowestRank, lowestRank < incomingRank else { return nil }
        return queue.firstIndex { Self.rank($0.record.priority) == lowestRank }
    }

    private func scheduleWorkerIfNeeded() {
        guard workerTask == nil,
              isAcceptingRecords,
              (!queue.isEmpty || (didInspectSpool && spooledRecordCount > 0))
        else { return }
        scheduleWorker(after: configuration.flushInterval)
    }

    private func scheduleWorker(after delay: Duration) {
        let token = UUID()
        workerToken = token
        let clock = self.clock
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                await self?.performDeliveryPass(token: token, reschedule: true)
            } catch {
                await self?.finishWorker(token: token, reschedule: true)
            }
        }
        workerTask = task
        taskStarted()
    }

    private func replaceScheduledWorkerWithImmediatePass() async {
        if let workerTask {
            // Invalidate before cancellation so the old task cannot schedule a
            // replacement while this explicit flush takes ownership.
            self.workerTask = nil
            workerToken = nil
            workerTask.cancel()
            await workerTask.value
            isDelivering = false
            taskEnded()
        }
        let token = UUID()
        workerToken = token
        let task = Task { [weak self] in
            _ = await self?.performDeliveryPass(token: token, reschedule: true)
        }
        workerTask = task
        taskStarted()
        await task.value
    }

    private func performDeliveryPass(token: UUID, reschedule: Bool) async {
        guard workerToken == token else { return }
        isDelivering = true
        publishSnapshot()

        var destinationAvailable = true
        if configuration.diskSpool != nil {
            destinationAvailable = await replaySpool()
        }
        while destinationAvailable, !queue.isEmpty, !Task.isCancelled {
            let records = dequeueBatch()
            destinationAvailable = await send(records)
            if !destinationAvailable {
                await spoolOrDrop(records)
            }
        }
        await finishWorker(token: token, reschedule: reschedule)
    }

    private func finishWorker(token: UUID, reschedule: Bool) async {
        guard workerToken == token else { return }
        workerTask = nil
        workerToken = nil
        isDelivering = false
        taskEnded()
        publishSnapshot()
        if reschedule, isAcceptingRecords,
           !queue.isEmpty || (didInspectSpool && spooledRecordCount > 0) {
            scheduleWorker(after: configuration.flushInterval)
        }
    }

    private func dequeueBatch() -> [PlaybackAnalyticsRecord] {
        var result: [PlaybackAnalyticsRecord] = []
        var bytes = 0
        while let next = queue.first,
              result.count < configuration.maximumBatchRecordCount {
            if !result.isEmpty, bytes > configuration.maximumBatchBytes - next.estimatedBytes {
                break
            }
            queue.removeFirst()
            queuedBytes -= next.estimatedBytes
            bytes += next.estimatedBytes
            result.append(next.record)
        }
        publishSnapshot()
        return result
    }

    private func send(_ records: [PlaybackAnalyticsRecord]) async -> Bool {
        guard !records.isEmpty else { return true }
        let batch = PlaybackAnalyticsBatch(records: records)
        for attempt in 1...configuration.retryPolicy.maximumAttempts {
            do {
                try Task.checkCancellation()
                try await sink.send(batch)
                deliveredBatchCount = Self.saturatingAdd(deliveredBatchCount, 1)
                deliveredRecordCount = Self.saturatingAdd(
                    deliveredRecordCount,
                    UInt64(records.count)
                )
                publishSnapshot()
                return true
            } catch {
                exportFailureCount = Self.saturatingAdd(exportFailureCount, 1)
                let disposition = (error as? any PlaybackAnalyticsRetryClassifyingError)?
                    .retryDisposition ?? .retryable
                guard disposition == .retryable,
                      attempt < configuration.retryPolicy.maximumAttempts,
                      !Task.isCancelled
                else {
                    publishSnapshot()
                    return false
                }
                retryCount = Self.saturatingAdd(retryCount, 1)
                publishSnapshot()
                do {
                    try await clock.sleep(
                        for: configuration.retryPolicy.delay(afterFailedAttempt: attempt)
                    )
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func replaySpool() async -> Bool {
        guard let spool = configuration.diskSpool else { return true }
        while !Task.isCancelled {
            let read: SpoolRead
            do {
                read = try await performDiskOperation {
                    try Self.readSpoolBatch(
                        spool,
                        maximumCount: self.configuration.maximumBatchRecordCount,
                        maximumBytes: self.configuration.maximumBatchBytes
                    )
                }
            } catch {
                didInspectSpool = true
                spoolFailureCount = Self.saturatingAdd(spoolFailureCount, 1)
                publishSnapshot()
                return false
            }
            didInspectSpool = true
            updateSpoolState(read.state)
            if read.corruptRecordCount > 0 {
                spoolFailureCount = Self.saturatingAdd(
                    spoolFailureCount,
                    UInt64(read.corruptRecordCount)
                )
            }
            guard !read.records.isEmpty else {
                publishSnapshot()
                return true
            }
            let records = read.records.map(\.record)
            guard await send(records) else { return false }
            do {
                let state = try await performDiskOperation {
                    try Self.removeSpoolFiles(read.records.map(\.file), configuration: spool)
                }
                updateSpoolState(state)
            } catch {
                // Delivery may be duplicated after a delete failure. Record IDs
                // make that explicit and safe for a conforming sink.
                spoolFailureCount = Self.saturatingAdd(spoolFailureCount, 1)
                publishSnapshot()
                return false
            }
        }
        return false
    }

    private func spoolOrDrop(_ records: [PlaybackAnalyticsRecord]) async {
        guard !records.isEmpty else { return }
        guard let spool = configuration.diskSpool else {
            records.forEach { incrementDrop(for: $0.priority) }
            publishSnapshot()
            return
        }
        do {
            let result = try await performDiskOperation {
                try Self.writeToSpool(records, configuration: spool)
            }
            didInspectSpool = true
            updateSpoolState(result.state)
            result.droppedPriorities.forEach { incrementDrop(for: $0) }
            spoolFailureCount = Self.saturatingAdd(
                spoolFailureCount,
                UInt64(result.failureCount)
            )
        } catch {
            spoolFailureCount = Self.saturatingAdd(spoolFailureCount, 1)
            records.forEach { incrementDrop(for: $0.priority) }
        }
        publishSnapshot()
    }

    private func performDiskOperation<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        taskStarted()
        defer { taskEnded() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func updateSpoolState(_ state: SpoolState) {
        spooledRecordCount = state.files.count
        spooledBytes = state.byteCount
        publishSnapshot()
    }

    private func taskStarted() {
        activeTaskCount += 1
        maximumObservedTaskCount = max(maximumObservedTaskCount, activeTaskCount)
        publishSnapshot()
    }

    private func taskEnded() {
        activeTaskCount = max(0, activeTaskCount - 1)
        publishSnapshot()
    }

    private func incrementDrop(for priority: PlaybackAnalytics.Priority) {
        switch priority {
        case .routine:
            droppedRoutineRecordCount = Self.saturatingAdd(droppedRoutineRecordCount, 1)
        case .important:
            droppedImportantRecordCount = Self.saturatingAdd(droppedImportantRecordCount, 1)
        case .critical:
            droppedCriticalRecordCount = Self.saturatingAdd(droppedCriticalRecordCount, 1)
        }
    }

    private func publishSnapshot() {
        snapshotContinuation.yield(snapshotValue())
    }

    private func snapshotValue() -> Snapshot {
        Snapshot(
            isAcceptingRecords: isAcceptingRecords,
            isDelivering: isDelivering,
            queuedRecordCount: queue.count,
            queuedBytes: queuedBytes,
            maximumQueuedRecordCount: configuration.maximumQueuedRecordCount,
            memoryBudgetBytes: configuration.memoryBudgetBytes,
            maximumObservedQueuedRecordCount: maximumObservedQueuedRecordCount,
            maximumObservedQueuedBytes: maximumObservedQueuedBytes,
            spooledRecordCount: spooledRecordCount,
            spooledBytes: spooledBytes,
            maximumSpooledRecordCount: configuration.diskSpool?.maximumRecordCount ?? 0,
            maximumSpoolBytes: configuration.diskSpool?.maximumBytes ?? 0,
            deliveredRecordCount: deliveredRecordCount,
            deliveredBatchCount: deliveredBatchCount,
            sampledOutRecordCount: sampledOutRecordCount,
            droppedRoutineRecordCount: droppedRoutineRecordCount,
            droppedImportantRecordCount: droppedImportantRecordCount,
            droppedCriticalRecordCount: droppedCriticalRecordCount,
            retryCount: retryCount,
            exportFailureCount: exportFailureCount,
            spoolFailureCount: spoolFailureCount,
            activeTaskCount: activeTaskCount,
            taskLimit: 3,
            maximumObservedTaskCount: maximumObservedTaskCount
        )
    }

    private static func isSampled(_ id: PlaybackAnalytics.RecordID, rate: Double) -> Bool {
        guard rate > 0 else { return false }
        guard rate < 1 else { return true }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.encodedValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 1_000_000) < rate * 1_000_000
    }

    private static func estimatedMemoryBytes(for record: PlaybackAnalyticsRecord) -> Int {
        let dimensionBytes: Int
        let measurementCount: Int
        switch record {
        case .event(let event):
            dimensionBytes = event.dimensions.values.reduce(0) { partial, pair in
                partial + pair.key.utf8.count + pair.value.utf8.count + 32
            }
            measurementCount = event.measurements.count
        case .summary(let summary):
            dimensionBytes = summary.dimensions.values.reduce(0) { partial, pair in
                partial + pair.key.utf8.count + pair.value.utf8.count + 32
            }
            measurementCount = summary.measurements.count
        }
        // Fixed typed fields plus conservative dictionary/array allocation.
        return 640 + dimensionBytes + measurementCount * 112
    }

    private static func rank(_ priority: PlaybackAnalytics.Priority) -> Int {
        switch priority {
        case .routine: 0
        case .important: 1
        case .critical: 2
        }
    }

    private static func priorityToken(_ priority: PlaybackAnalytics.Priority) -> String {
        switch priority {
        case .routine: "0-routine"
        case .important: "1-important"
        case .critical: "2-critical"
        }
    }

    private static func priority(from filename: String) -> PlaybackAnalytics.Priority? {
        if filename.hasPrefix("0-routine-") { return .routine }
        if filename.hasPrefix("1-important-") { return .important }
        if filename.hasPrefix("2-critical-") { return .critical }
        return nil
    }

    private static func spoolDirectory(_ configuration: Configuration.DiskSpool) -> URL {
        configuration.directory.appendingPathComponent(
            "hlsproxy-playback-analytics-v1",
            isDirectory: true
        )
    }

    private static func inspectSpool(
        _ configuration: Configuration.DiskSpool
    ) throws -> SpoolState {
        let fileManager = FileManager()
        let directory = spoolDirectory(configuration)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let files = try urls.compactMap { url -> SpoolFile? in
            guard url.pathExtension == "json",
                  let priority = priority(from: url.lastPathComponent)
            else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            return SpoolFile(
                url: url,
                byteCount: max(0, values.fileSize ?? 0),
                priority: priority,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        return SpoolState(files: files)
    }

    private static func readSpoolBatch(
        _ configuration: Configuration.DiskSpool,
        maximumCount: Int,
        maximumBytes: Int
    ) throws -> SpoolRead {
        let fileManager = FileManager()
        var state = try inspectSpool(configuration)
        var records: [(file: SpoolFile, record: PlaybackAnalyticsRecord)] = []
        var bytes = 0
        var corruptRecordCount = 0
        for file in state.files where records.count < maximumCount {
            if !records.isEmpty, bytes > maximumBytes - file.byteCount { break }
            do {
                let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
                let record = try JSONDecoder().decode(PlaybackAnalyticsRecord.self, from: data)
                records.append((file, record))
                bytes += file.byteCount
            } catch {
                try? fileManager.removeItem(at: file.url)
                corruptRecordCount += 1
            }
        }
        if corruptRecordCount > 0 {
            state = try inspectSpool(configuration)
        }
        return SpoolRead(records: records, state: state, corruptRecordCount: corruptRecordCount)
    }

    private static func removeSpoolFiles(
        _ files: [SpoolFile],
        configuration: Configuration.DiskSpool
    ) throws -> SpoolState {
        let fileManager = FileManager()
        for file in files {
            do {
                try fileManager.removeItem(at: file.url)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
        return try inspectSpool(configuration)
    }

    private static func writeToSpool(
        _ records: [PlaybackAnalyticsRecord],
        configuration: Configuration.DiskSpool
    ) throws -> SpoolWriteResult {
        let fileManager = FileManager()
        let directory = spoolDirectory(configuration)
        var state = try inspectSpool(configuration)
        var droppedPriorities: [PlaybackAnalytics.Priority] = []
        var failureCount = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for record in records {
            do {
                let data = try encoder.encode(record)
                guard data.count <= configuration.maximumBytes else {
                    droppedPriorities.append(record.priority)
                    continue
                }
                let filename = "\(priorityToken(record.priority))-\(record.idempotencyID.encodedValue).json"
                let url = directory.appendingPathComponent(filename, isDirectory: false)
                if fileManager.fileExists(atPath: url.path) { continue }

                while state.files.count >= configuration.maximumRecordCount
                    || state.byteCount > configuration.maximumBytes - data.count {
                    guard let victim = spoolVictim(
                        in: state.files,
                        forIncoming: record.priority
                    ) else {
                        droppedPriorities.append(record.priority)
                        break
                    }
                    try fileManager.removeItem(at: victim.url)
                    droppedPriorities.append(victim.priority)
                    state = try inspectSpool(configuration)
                }
                guard state.files.count < configuration.maximumRecordCount,
                      state.byteCount <= configuration.maximumBytes - data.count
                else { continue }
                try data.write(to: url, options: [.atomic])
                state = try inspectSpool(configuration)
            } catch {
                failureCount += 1
                droppedPriorities.append(record.priority)
            }
        }
        return SpoolWriteResult(
            state: state,
            droppedPriorities: droppedPriorities,
            failureCount: failureCount
        )
    }

    private static func spoolVictim(
        in files: [SpoolFile],
        forIncoming priority: PlaybackAnalytics.Priority
    ) -> SpoolFile? {
        let incomingRank = rank(priority)
        let lowerPriorities = files.filter { rank($0.priority) < incomingRank }
        guard let lowestRank = lowerPriorities.map({ rank($0.priority) }).min() else {
            return nil
        }
        return lowerPriorities.first { rank($0.priority) == lowestRank }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
