import Foundation

public actor PlaylistRefreshController {
    public struct Configuration: Sendable, Equatable {
        public var refreshInterval: TimeInterval
        public var maxBackoffInterval: TimeInterval

        public init(refreshInterval: TimeInterval = 2, maxBackoffInterval: TimeInterval = 8) {
            self.refreshInterval = refreshInterval
            self.maxBackoffInterval = max(maxBackoffInterval, refreshInterval)
        }
    }

    public struct LowLatencyConfiguration: Sendable, Equatable {
        public var isEnabled: Bool
        public var blockingRequestTimeout: TimeInterval
        public var enableDeltaUpdates: Bool

        public init(
            isEnabled: Bool = false,
            blockingRequestTimeout: TimeInterval = 6,
            enableDeltaUpdates: Bool = false
        ) {
            self.isEnabled = isEnabled
            self.blockingRequestTimeout = blockingRequestTimeout
            self.enableDeltaUpdates = enableDeltaUpdates
        }
    }

    public struct Metrics: Sendable, Equatable {
        public let lastRefreshDate: Date?
        public let consecutiveFailures: Int
        public let lastErrorDescription: String?
        public let remoteMediaSequence: Int?
        public let blockingReloadEngaged: Bool

        public init(
            lastRefreshDate: Date? = nil,
            consecutiveFailures: Int = 0,
            lastErrorDescription: String? = nil,
            remoteMediaSequence: Int? = nil,
            blockingReloadEngaged: Bool = false
        ) {
            self.lastRefreshDate = lastRefreshDate
            self.consecutiveFailures = consecutiveFailures
            self.lastErrorDescription = lastErrorDescription
            self.remoteMediaSequence = remoteMediaSequence
            self.blockingReloadEngaged = blockingReloadEngaged
        }
    }

    public enum RefreshError: Error, Equatable {
        case missingSourceURL
        case mediaPlaylistUnavailable
    }

    private var configuration: Configuration
    private let session: URLSession
    private let logger: Logger

    private var task: Task<Void, Never>?
    private var sourceURL: URL?
    private var allowInsecure = false
    private var retryPolicy: HLSManifestFetcher.RetryPolicy = .default
    private var parser = HLSParser()
    private var onUpdate: (@Sendable (MediaPlaylist) async -> Void)?
    private var isEnded = false
    private var lowLatencyConfiguration: LowLatencyConfiguration?
    private var lastBlockingReference: BlockingReference?
    private var lastServerControl: HLSServerControl?

    private var lastRefreshDate: Date?
    private var consecutiveFailures = 0
    private var lastErrorDescription: String?
    private var remoteMediaSequence: Int?

    private struct BlockingReference {
        let sequence: Int
        let partIndex: Int?
    }

    public init(
        configuration: Configuration = .init(),
        session: URLSession = .shared,
        logger: Logger = DefaultLogger()
    ) {
        self.configuration = configuration
        self.session = session
        self.logger = logger
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public func updateLowLatencyConfiguration(_ configuration: LowLatencyConfiguration?) {
        lowLatencyConfiguration = configuration
    }

    public func start(
        url: URL,
        allowInsecure: Bool,
        retryPolicy: HLSManifestFetcher.RetryPolicy,
        onUpdate: @escaping @Sendable (MediaPlaylist) async -> Void
    ) {
        stopCurrentTask()
        sourceURL = url
        self.allowInsecure = allowInsecure
        self.retryPolicy = retryPolicy
        self.onUpdate = onUpdate
        isEnded = false
        consecutiveFailures = 0
        lastErrorDescription = nil
        lastBlockingReference = nil
        lastServerControl = nil
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stopCurrentTask()
        sourceURL = nil
        onUpdate = nil
        isEnded = false
        lastBlockingReference = nil
        lastServerControl = nil
    }

    public func metrics() -> Metrics {
        Metrics(
            lastRefreshDate: lastRefreshDate,
            consecutiveFailures: consecutiveFailures,
            lastErrorDescription: lastErrorDescription,
            remoteMediaSequence: remoteMediaSequence,
            blockingReloadEngaged: (lowLatencyConfiguration?.isEnabled ?? false) && (lastServerControl?.canBlockReload ?? false)
        )
    }

    private func stopCurrentTask() {
        task?.cancel()
        task = nil
    }

    private func runLoop() async {
        guard sourceURL != nil else { return }
        var currentDelay = configuration.refreshInterval

        while !Task.isCancelled && !isEnded {
            do {
                let (requestURL, timeout, wasBlocking) = nextRequestParameters()
                let playlist = try await fetchPlaylist(from: requestURL, requestTimeout: timeout)
                updateBlockingMetadata(from: playlist)
                await onUpdate?(playlist)
                lastRefreshDate = Date()
                consecutiveFailures = 0
                lastErrorDescription = nil
                remoteMediaSequence = playlist.mediaSequence
                currentDelay = nextDelay(after: playlist, wasBlocking: wasBlocking)
                if playlist.isEndlist {
                    isEnded = true
                }
            } catch {
                consecutiveFailures += 1
                lastErrorDescription = error.localizedDescription
                logger.log("Playlist refresh failed: \(error)", category: .manifest)
                currentDelay = min(configuration.maxBackoffInterval, max(configuration.refreshInterval, currentDelay * 2))
            }

            if Task.isCancelled || isEnded { break }
            guard currentDelay > 0 else { continue }
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, currentDelay) * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func fetchPlaylist(from url: URL, requestTimeout: TimeInterval?) async throws -> MediaPlaylist {
        let fetcher = HLSManifestFetcher(
            url: url,
            session: session,
            retryPolicy: retryPolicy,
            logger: logger
        )
        let text = try await fetcher.fetchManifest(from: url, allowInsecure: allowInsecure, requestTimeout: requestTimeout)
        let manifest = try parser.parse(text, baseURL: url)
        guard let playlist = manifest.mediaPlaylist else {
            throw RefreshError.mediaPlaylistUnavailable
        }
        return playlist
    }

    private func nextRequestParameters() -> (URL, TimeInterval?, Bool) {
        guard let baseURL = sourceURL else { return (URL(fileURLWithPath: "/"), nil, false) }
        guard
            let lowLatencyConfiguration,
            lowLatencyConfiguration.isEnabled,
            let control = lastServerControl,
            control.canBlockReload,
            let reference = lastBlockingReference
        else {
            return (baseURL, nil, false)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { ["_HLS_msn", "_HLS_part", "_HLS_skip"].contains($0.name) }
        items.append(URLQueryItem(name: "_HLS_msn", value: String(reference.sequence)))
        if let partIndex = reference.partIndex {
            items.append(URLQueryItem(name: "_HLS_part", value: String(partIndex)))
        }
        if lowLatencyConfiguration.enableDeltaUpdates {
            items.append(URLQueryItem(name: "_HLS_skip", value: "YES"))
        }
        components?.queryItems = items
        return (
            components?.url ?? baseURL,
            lowLatencyConfiguration.blockingRequestTimeout,
            true
        )
    }

    private func updateBlockingMetadata(from playlist: MediaPlaylist) {
        lastServerControl = playlist.serverControl
        guard let lastSegment = playlist.segments.last else {
            lastBlockingReference = nil
            return
        }
        let partIndex = lastSegment.parts.last?.partIndex
        lastBlockingReference = BlockingReference(sequence: lastSegment.sequence, partIndex: partIndex)
    }

    private func nextDelay(after playlist: MediaPlaylist, wasBlocking: Bool) -> TimeInterval {
        if wasBlocking, lowLatencyConfiguration?.isEnabled == true {
            return 0
        }
        if let lowLatencyConfiguration, lowLatencyConfiguration.isEnabled,
           let holdBack = playlist.serverControl?.partHoldBack, holdBack > 0 {
            return max(0.05, holdBack / 2)
        }
        return configuration.refreshInterval
    }
}
