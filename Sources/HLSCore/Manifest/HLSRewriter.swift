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

    public func partialSegmentURL(for sequence: Int, partIndex: Int, namespace: String? = nil) -> URL {
        let key = SegmentIdentity.key(forPartSequence: sequence, partIndex: partIndex, namespace: namespace)
        return proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(key)
    }
}

public struct BufferState: Sendable {
    public let readySequences: Set<Int>
    public let readyPartCounts: [Int: Int]
    public let prefetchDepthSeconds: Double
    public let partPrefetchDepthSeconds: Double
    public let playedThroughSequence: Int?

    public init(
        readySequences: Set<Int> = [],
        readyPartCounts: [Int: Int] = [:],
        prefetchDepthSeconds: Double = 0,
        partPrefetchDepthSeconds: Double = 0,
        playedThroughSequence: Int? = nil
    ) {
        self.readySequences = readySequences
        self.readyPartCounts = readyPartCounts
        self.prefetchDepthSeconds = prefetchDepthSeconds
        self.partPrefetchDepthSeconds = partPrefetchDepthSeconds
        self.playedThroughSequence = playedThroughSequence
    }

    public func isReady(_ segment: HLSSegment) -> Bool {
        if let played = playedThroughSequence, segment.sequence <= played {
            return true
        }
        return readySequences.contains(segment.sequence)
    }

    public func readyPartCount(for sequence: Int) -> Int {
        readyPartCounts[sequence] ?? 0
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
        let lowLatencyEnabled = config.lowLatencyOptions != nil || mediaPlaylist.serverControl != nil || mediaPlaylist.partTargetDuration != nil
        lines.append(lowLatencyEnabled ? "#EXT-X-VERSION:7" : "#EXT-X-VERSION:3")

        if let target = mediaPlaylist.targetDuration {
            lines.append("#EXT-X-TARGETDURATION:\(Int(ceil(target)))")
        }

        if let bandwidth = config.artificialBandwidth {
            lines.append("#EXT-X-SESSION-DATA:DATA-ID=\"com.hlsproxy.bandwidth\",VALUE=\"\(bandwidth)\"")
        }

        if let attributes = serverControlAttributes(
            from: config.lowLatencyOptions,
            playlistControl: mediaPlaylist.serverControl
        ), !attributes.isEmpty {
            lines.append("#EXT-X-SERVER-CONTROL:\(attributes.joined(separator: ","))")
        }

        if lowLatencyEnabled {
            if let partTarget = mediaPlaylist.partTargetDuration ?? mediaPlaylist.serverControl?.partTarget {
                lines.append("#EXT-X-PART-INF:PART-TARGET=\(String(format: "%.3f", partTarget))")
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

        var pendingSegments: [HLSSegment] = []
        var lastMap: MediaInitializationMap?
        var lastEncryption: SegmentEncryption?

        for segment in mediaPlaylist.segments where segment.sequence >= lowestVisibleSequence {
            appendMetadataIfNeeded(
                for: segment,
                lines: &lines,
                lastMap: &lastMap,
                lastEncryption: &lastEncryption,
                resolver: config.keyURLResolver
            )
            if let partLines = renderParts(
                for: segment,
                bufferState: bufferState,
                configuration: config,
                namespace: namespace
            ), !partLines.isEmpty {
                lines.append(contentsOf: partLines)
            }

            if config.hideUntilBuffered && !bufferState.isReady(segment) {
                pendingSegments.append(segment)
                continue
            }

            let durationString = String(format: "%.3f", segment.duration)
            lines.append("#EXTINF:\(durationString),")
            lines.append(config.segmentURL(for: segment.sequence, namespace: namespace).absoluteString)
        }

        if config.hideUntilBuffered && !pendingSegments.isEmpty {
            logger.log(
                "Hiding \(pendingSegments.count) of \(mediaPlaylist.segments.count) segments until buffered.",
                category: .rewriter
            )
        }

        if lowLatencyEnabled {
            lines.append(contentsOf: renderPreloadHints(
                mediaPlaylist.preloadHints,
                namespace: namespace,
                configuration: config
            ))
        }

        lines.append(contentsOf: renderRenditionReports(mediaPlaylist.renditionReports))

        if
            let lowLatency = config.lowLatencyOptions,
            lowLatency.enableDeltaUpdates,
            !pendingSegments.isEmpty
        {
            let skipCount = mediaPlaylist.skippedSegmentCount ?? pendingSegments.count
            lines.append("#EXT-X-SKIP:SKIPPED-SEGMENTS=\(skipCount)")
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
        if pendingSegments.isEmpty && mediaPlaylist.isEndlist {
            lines.append("#EXT-X-ENDLIST")
        }

        return lines.joined(separator: "\n")
    }

    private func serverControlAttributes(
        from options: HLSRewriteConfiguration.LowLatencyOptions?,
        playlistControl: HLSServerControl?
    ) -> [String]? {
        var attributes: [String] = []
        if let skip = options?.canSkipUntil ?? playlistControl?.canSkipUntil {
            attributes.append("CAN-SKIP-UNTIL=\(String(format: "%.3f", skip))")
        }
        if (options?.allowBlockingReload ?? false) || (playlistControl?.canBlockReload ?? false) {
            attributes.append("CAN-BLOCK-RELOAD=YES")
        }
        if (options?.prefetchHintCount ?? 0) > 0 || (playlistControl?.canPrefetch ?? false) {
            attributes.append("CAN-PREFETCH=YES")
        }
        if playlistControl?.canSkipDateRanges == true {
            attributes.append("CAN-SKIP-DATERANGES=YES")
        }
        if let holdBack = playlistControl?.holdBack {
            attributes.append("HOLD-BACK=\(String(format: "%.3f", holdBack))")
        }
        if let partHoldBack = playlistControl?.partHoldBack {
            attributes.append("PART-HOLD-BACK=\(String(format: "%.3f", partHoldBack))")
        }
        return attributes.isEmpty ? nil : attributes
    }

    private func renderParts(
        for segment: HLSSegment,
        bufferState: BufferState,
        configuration: HLSRewriteConfiguration,
        namespace: String?
    ) -> [String]? {
        guard configuration.lowLatencyOptions != nil else { return nil }
        guard !segment.parts.isEmpty else { return nil }
        let readyCount = bufferState.readyPartCount(for: segment.sequence)
        let shouldLimitToReady = configuration.hideUntilBuffered
        let limit = shouldLimitToReady ? readyCount : segment.parts.count
        guard limit > 0 else { return nil }
        let parts = segment.parts.prefix(limit)
        return parts.map { renderPartLine(for: $0, namespace: namespace, configuration: configuration) }
    }

    private func renderPartLine(
        for part: HLSPartialSegment,
        namespace: String?,
        configuration: HLSRewriteConfiguration
    ) -> String {
        var attributes: [String] = []
        attributes.append("DURATION=\(String(format: "%.3f", part.duration))")
        let url = configuration.partialSegmentURL(for: part.parentSequence, partIndex: part.partIndex, namespace: namespace)
        attributes.append("URI=\(url.absoluteString)")
        if let range = part.byteRange {
            attributes.append("BYTERANGE=\(byteRangeString(for: range))")
        }
        if part.isIndependent {
            attributes.append("INDEPENDENT=YES")
        }
        if part.isGap {
            attributes.append("GAP=YES")
        }
        return "#EXT-X-PART:\(attributes.joined(separator: ","))"
    }

    private func renderPreloadHints(
        _ hints: [HLSPreloadHint],
        namespace: String?,
        configuration: HLSRewriteConfiguration
    ) -> [String] {
        hints.map { hint in
            var attributes: [String] = []
            attributes.append("TYPE=\(hint.type.rawValue)")
            let uri: URL
            if hint.type == .part, let partIndex = hint.partIndex {
                uri = configuration.partialSegmentURL(for: hint.sequence, partIndex: partIndex, namespace: namespace)
            } else {
                uri = hint.uri
            }
            attributes.append("URI=\(uri.absoluteString)")
            if let start = hint.byteRangeStart {
                attributes.append("BYTERANGE-START=\(start)")
            }
            if let length = hint.byteRangeLength {
                attributes.append("BYTERANGE-LENGTH=\(length)")
            }
            return "#EXT-X-PRELOAD-HINT:\(attributes.joined(separator: ","))"
        }
    }

    private func renderRenditionReports(_ reports: [HLSRenditionReport]) -> [String] {
        reports.map { report in
            var attributes: [String] = []
            attributes.append("URI=\(report.uri.absoluteString)")
            if let msn = report.lastMediaSequence {
                attributes.append("LAST-MSN=\(msn)")
            }
            if let part = report.lastPartIndex {
                attributes.append("LAST-PART=\(part)")
            }
            if let bitrate = report.averageBandwidth {
                attributes.append("AVERAGE-BANDWIDTH=\(bitrate)")
            }
            return "#EXT-X-RENDITION-REPORT:\(attributes.joined(separator: ","))"
        }
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
