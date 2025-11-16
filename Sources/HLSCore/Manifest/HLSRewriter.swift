import Foundation

public struct HLSRewriteConfiguration: Sendable {
    public enum QualityPolicy: Sendable, Equatable {
        case automatic
        case locked(QualityProfile)
    }

    public struct LowLatencyOptions: Sendable, Equatable {
        public let canSkipUntil: TimeInterval?
        public let partHoldBack: TimeInterval?
        public let allowBlockingReload: Bool
        public let prefetchHintCount: Int
        public let enableDeltaUpdates: Bool

        public init(
            canSkipUntil: TimeInterval? = nil,
            partHoldBack: TimeInterval? = nil,
            allowBlockingReload: Bool = false,
            prefetchHintCount: Int = 0,
            enableDeltaUpdates: Bool = false
        ) {
            self.canSkipUntil = canSkipUntil
            self.partHoldBack = partHoldBack
            self.allowBlockingReload = allowBlockingReload
            self.prefetchHintCount = prefetchHintCount
            self.enableDeltaUpdates = enableDeltaUpdates
        }
    }

    public typealias KeyURLResolver = @Sendable (HLSKey) -> URL?

    public let proxyBaseURL: URL
    public let playlistFilename: String
    public let segmentPathPrefix: String
    public let hideUntilBuffered: Bool
    public let artificialBandwidth: Int?
    public let qualityPolicy: QualityPolicy
    public let lowLatencyOptions: LowLatencyOptions?
    public let keyURLResolver: KeyURLResolver?

    public init(
        proxyBaseURL: URL,
        playlistFilename: String = "playlist.m3u8",
        segmentPathPrefix: String = "segments",
        hideUntilBuffered: Bool = false,
        artificialBandwidth: Int? = nil,
        qualityPolicy: QualityPolicy = .automatic,
        lowLatencyOptions: LowLatencyOptions? = nil,
        keyURLResolver: KeyURLResolver? = nil
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.playlistFilename = playlistFilename
        self.segmentPathPrefix = segmentPathPrefix
        self.hideUntilBuffered = hideUntilBuffered
        self.artificialBandwidth = artificialBandwidth
        self.qualityPolicy = qualityPolicy
        self.lowLatencyOptions = lowLatencyOptions
        self.keyURLResolver = keyURLResolver
    }

    public var playlistURL: URL {
        proxyBaseURL.appendingPathComponent(playlistFilename)
    }

    public func segmentURL(for sequence: Int, namespace: String? = nil) -> URL {
        let key = SegmentIdentity.key(forSequence: sequence, namespace: namespace)
        return proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(key)
    }
}

public struct BufferState: Sendable {
    public let readySequences: Set<Int>
    public let prefetchDepthSeconds: Double
    public let playedThroughSequence: Int?

    public init(
        readySequences: Set<Int> = [],
        prefetchDepthSeconds: Double = 0,
        playedThroughSequence: Int? = nil
    ) {
        self.readySequences = readySequences
        self.prefetchDepthSeconds = prefetchDepthSeconds
        self.playedThroughSequence = playedThroughSequence
    }

    public func isReady(_ segment: HLSSegment) -> Bool {
        if let played = playedThroughSequence, segment.sequence <= played {
            return true
        }
        return readySequences.contains(segment.sequence)
    }
}

public final class HLSRewriter: @unchecked Sendable {
    private let logger: Logger

    public init(logger: Logger = DefaultLogger()) {
        self.logger = logger
    }

    public func rewrite(
        mediaPlaylist: MediaPlaylist,
        config: HLSRewriteConfiguration,
        bufferState: BufferState,
        namespace: String? = nil
    ) -> String {
        var lines: [String] = ["#EXTM3U"]
        lines.append(config.lowLatencyOptions == nil ? "#EXT-X-VERSION:3" : "#EXT-X-VERSION:7")

        if let target = mediaPlaylist.targetDuration {
            lines.append("#EXT-X-TARGETDURATION:\(Int(ceil(target)))")
        }

        if let bandwidth = config.artificialBandwidth {
            lines.append("#EXT-X-SESSION-DATA:DATA-ID=\"com.hlsproxy.bandwidth\",VALUE=\"\(bandwidth)\"")
        }

        if let lowLatency = config.lowLatencyOptions {
            let attributes = serverControlAttributes(from: lowLatency)
            if !attributes.isEmpty {
                lines.append("#EXT-X-SERVER-CONTROL:\(attributes.joined(separator: ","))")
            }
            if let partHoldBack = lowLatency.partHoldBack {
                lines.append("#EXT-X-PART-INF:PART-TARGET=\(String(format: "%.3f", partHoldBack))")
            }
        }

        let historyWindow = 4
        let lowestVisibleSequence: Int = {
            if let played = bufferState.playedThroughSequence {
                return max(mediaPlaylist.mediaSequence, played - historyWindow + 1)
            }
            return mediaPlaylist.mediaSequence
        }()

        lines.append("#EXT-X-MEDIA-SEQUENCE:\(lowestVisibleSequence)")

        if !mediaPlaylist.sessionKeys.isEmpty {
            for key in mediaPlaylist.sessionKeys {
                if let keyLine = renderKeyLine(
                    prefix: "#EXT-X-SESSION-KEY",
                    key: key,
                    initializationVector: nil,
                    resolver: config.keyURLResolver
                ) {
                    lines.append(keyLine)
                }
            }
        }

        var visibleSegments: [HLSSegment] = []
        var pendingSegments: [HLSSegment] = []

        for segment in mediaPlaylist.segments where segment.sequence >= lowestVisibleSequence {
            if config.hideUntilBuffered && !bufferState.isReady(segment) {
                pendingSegments.append(segment)
            } else {
                visibleSegments.append(segment)
            }
        }

        if config.hideUntilBuffered && !pendingSegments.isEmpty {
            logger.log(
                "Hiding \(pendingSegments.count) of \(mediaPlaylist.segments.count) segments until buffered.",
                category: .rewriter
            )
        }

        if
            let lowLatency = config.lowLatencyOptions,
            lowLatency.enableDeltaUpdates,
            !pendingSegments.isEmpty
        {
            lines.append("#EXT-X-SKIP:SKIPPED-SEGMENTS=\(pendingSegments.count)")
        }

        var lastMap: MediaInitializationMap?
        var lastEncryption: SegmentEncryption?

        for segment in visibleSegments {
            let durationString = String(format: "%.3f", segment.duration)
            appendMetadataIfNeeded(
                for: segment,
                lines: &lines,
                lastMap: &lastMap,
                lastEncryption: &lastEncryption,
                resolver: config.keyURLResolver
            )
            lines.append("#EXTINF:\(durationString),")
            lines.append(config.segmentURL(for: segment.sequence, namespace: namespace).absoluteString)
        }

        if
            let lowLatency = config.lowLatencyOptions,
            lowLatency.prefetchHintCount > 0
        {
            for segment in pendingSegments.prefix(lowLatency.prefetchHintCount) {
                appendMetadataIfNeeded(
                    for: segment,
                    lines: &lines,
                    lastMap: &lastMap,
                    lastEncryption: &lastEncryption,
                    resolver: config.keyURLResolver
                )
                lines.append("#EXT-X-PREFETCH:\(config.segmentURL(for: segment.sequence, namespace: namespace).absoluteString)")
            }
        }

        lines.append("#EXT-X-PREFETCH-DISTANCE:\(String(format: "%.2f", bufferState.prefetchDepthSeconds))")
        if pendingSegments.isEmpty {
            lines.append("#EXT-X-ENDLIST")
        }

        return lines.joined(separator: "\n")
    }

    private func serverControlAttributes(from options: HLSRewriteConfiguration.LowLatencyOptions) -> [String] {
        var attributes: [String] = []
        if let skip = options.canSkipUntil {
            attributes.append("CAN-SKIP-UNTIL=\(String(format: "%.3f", skip))")
        }
        if options.allowBlockingReload {
            attributes.append("CAN-BLOCK-RELOAD=YES")
        }
        if options.prefetchHintCount > 0 {
            attributes.append("CAN-PREFETCH=YES")
        }
        return attributes
    }

    private func appendMetadataIfNeeded(
        for segment: HLSSegment,
        lines: inout [String],
        lastMap: inout MediaInitializationMap?,
        lastEncryption: inout SegmentEncryption?,
        resolver: HLSRewriteConfiguration.KeyURLResolver?
    ) {
        if segment.initializationMap != lastMap {
            if let map = segment.initializationMap {
                lines.append(renderMapLine(for: map))
            }
            lastMap = segment.initializationMap
        }

        if segment.encryption != lastEncryption {
            if let encryption = segment.encryption,
               let keyLine = renderKeyLine(
                    prefix: "#EXT-X-KEY",
                    key: encryption.key,
                    initializationVector: encryption.initializationVector,
                    resolver: resolver
                ) {
                lines.append(keyLine)
            }
            lastEncryption = segment.encryption
        }
    }

    private func renderKeyLine(
        prefix: String,
        key: HLSKey,
        initializationVector: String?,
        resolver: HLSRewriteConfiguration.KeyURLResolver?
    ) -> String? {
        var attributes: [String] = []
        attributes.append("METHOD=\(key.method.rawValue)")

        if let uri = resolvedKeyURI(for: key, resolver: resolver) {
            attributes.append("URI=\"\(uri.absoluteString)\"")
        }

        if let keyFormat = key.keyFormat {
            attributes.append("KEYFORMAT=\"\(keyFormat)\"")
        }

        if !key.keyFormatVersions.isEmpty {
            let joined = key.keyFormatVersions.joined(separator: "/")
            attributes.append("KEYFORMATVERSIONS=\"\(joined)\"")
        }

        if let initializationVector {
            attributes.append("IV=\(initializationVector)")
        }

        return "\(prefix):\(attributes.joined(separator: ","))"
    }

    private func renderMapLine(for map: MediaInitializationMap) -> String {
        var attributes: [String] = []
        attributes.append("URI=\"\(map.uri.absoluteString)\"")
        if let range = map.byteRange {
            attributes.append("BYTERANGE=\(byteRangeString(for: range))")
        }
        return "#EXT-X-MAP:\(attributes.joined(separator: ","))"
    }

    private func resolvedKeyURI(
        for key: HLSKey,
        resolver: HLSRewriteConfiguration.KeyURLResolver?
    ) -> URL? {
        guard key.method != .none else { return nil }
        guard let currentURI = key.uri else { return nil }
        if let resolver, let rewritten = resolver(key) {
            return rewritten
        }
        return currentURI
    }

    private func byteRangeString(for range: ClosedRange<Int>) -> String {
        let length = range.upperBound - range.lowerBound + 1
        return "\(length)@\(range.lowerBound)"
    }
}
