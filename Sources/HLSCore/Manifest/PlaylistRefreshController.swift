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

    public struct Metrics: Sendable, Equatable {
        public let lastRefreshDate: Date?
        public let consecutiveFailures: Int
        public let lastErrorDescription: String?
        public let remoteMediaSequence: Int?

        public init(
            lastRefreshDate: Date? = nil,
            consecutiveFailures: Int = 0,
            lastErrorDescription: String? = nil,
            remoteMediaSequence: Int? = nil
        ) {
            self.lastRefreshDate = lastRefreshDate
            self.consecutiveFailures = consecutiveFailures
            self.lastErrorDescription = lastErrorDescription
            self.remoteMediaSequence = remoteMediaSequence
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

    private var lastRefreshDate: Date?
    private var consecutiveFailures = 0
    private var lastErrorDescription: String?
    private var remoteMediaSequence: Int?

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
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stopCurrentTask()
        sourceURL = nil
        onUpdate = nil
        isEnded = false
    }

    public func metrics() -> Metrics {
        Metrics(
            lastRefreshDate: lastRefreshDate,
            consecutiveFailures: consecutiveFailures,
            lastErrorDescription: lastErrorDescription,
            remoteMediaSequence: remoteMediaSequence
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
                let playlist = try await fetchPlaylist()
                await onUpdate?(playlist)
                lastRefreshDate = Date()
                consecutiveFailures = 0
                lastErrorDescription = nil
                remoteMediaSequence = playlist.mediaSequence
                currentDelay = configuration.refreshInterval
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
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, currentDelay) * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func fetchPlaylist() async throws -> MediaPlaylist {
        guard let url = sourceURL else { throw RefreshError.missingSourceURL }
        let fetcher = HLSManifestFetcher(
            url: url,
            session: session,
            retryPolicy: retryPolicy,
            logger: logger
        )
        let text = try await fetcher.fetchManifest(from: url, allowInsecure: allowInsecure)
        let manifest = try parser.parse(text, baseURL: url)
        guard let playlist = manifest.mediaPlaylist else {
            throw RefreshError.mediaPlaylistUnavailable
        }
        return playlist
    }
}
