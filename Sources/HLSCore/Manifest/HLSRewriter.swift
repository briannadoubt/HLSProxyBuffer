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
    public typealias RenditionReportURLResolver = @Sendable (HLSRenditionReport) -> URL?

    public let proxyBaseURL: URL
    public let playlistFilename: String
    public let segmentPathPrefix: String
    public let hideUntilBuffered: Bool
    public let artificialBandwidth: Int?
    public let qualityPolicy: QualityPolicy
    public let lowLatencyOptions: LowLatencyOptions?
    public let keyURLResolver: KeyURLResolver?
    public let renditionReportURLResolver: RenditionReportURLResolver?

    public init(
        proxyBaseURL: URL,
        playlistFilename: String = "playlist.m3u8",
        segmentPathPrefix: String = "segments",
        hideUntilBuffered: Bool = false,
        artificialBandwidth: Int? = nil,
        qualityPolicy: QualityPolicy = .automatic,
        lowLatencyOptions: LowLatencyOptions? = nil,
        keyURLResolver: KeyURLResolver? = nil,
        renditionReportURLResolver: RenditionReportURLResolver? = nil
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.playlistFilename = playlistFilename
        self.segmentPathPrefix = segmentPathPrefix
        self.hideUntilBuffered = hideUntilBuffered
        self.artificialBandwidth = artificialBandwidth
        self.qualityPolicy = qualityPolicy
        self.lowLatencyOptions = lowLatencyOptions
        self.keyURLResolver = keyURLResolver
        self.renditionReportURLResolver = renditionReportURLResolver
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

    public func segmentURL(for segment: HLSSegment, namespace: String? = nil) -> URL {
        proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(SegmentIdentity.key(for: segment, namespace: namespace))
    }

    public func partialSegmentURL(for sequence: Int, partIndex: Int, namespace: String? = nil) -> URL {
        let key = SegmentIdentity.key(forPartSequence: sequence, partIndex: partIndex, namespace: namespace)
        return proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(key)
    }

    public func partialSegmentURL(for part: HLSPartialSegment, namespace: String? = nil) -> URL {
        proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(SegmentIdentity.key(for: part, namespace: namespace))
    }

    public func initializationMapURL(for map: MediaInitializationMap, namespace: String? = nil) -> URL {
        proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(SegmentIdentity.key(for: map, namespace: namespace))
    }

    public func preloadHintURL(for hint: HLSPreloadHint, namespace: String? = nil) -> URL {
        proxyBaseURL
            .appendingPathComponent(segmentPathPrefix)
            .appendingPathComponent(SegmentIdentity.key(for: hint, namespace: namespace))
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

public struct HLSRewriter: Sendable {
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
        let lowLatencyEnabled = config.lowLatencyOptions != nil
            || mediaPlaylist.serverControl != nil
            || mediaPlaylist.partTargetDuration != nil
            || !mediaPlaylist.trailingParts.isEmpty
        let minimumVersion = lowLatencyEnabled ? 10 : 3
        lines.append("#EXT-X-VERSION:\(max(mediaPlaylist.protocolVersion ?? minimumVersion, minimumVersion))")

        if mediaPlaylist.independentSegments {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        if let playlistType = mediaPlaylist.playlistType {
            lines.append("#EXT-X-PLAYLIST-TYPE:\(playlistType)")
        }
        if let startTag = mediaPlaylist.startTag {
            lines.append(startTag)
        }
        if let discontinuitySequence = mediaPlaylist.discontinuitySequence {
            lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)")
        }
        lines.append(contentsOf: mediaPlaylist.passthroughTags)

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
            let visibleParts = visibleParts(
                for: segment,
                bufferState: bufferState,
                configuration: config
            ) ?? []
            if config.hideUntilBuffered && !bufferState.isReady(segment) && visibleParts.isEmpty {
                pendingSegments.append(segment)
                continue
            }
            lines.append(contentsOf: segment.metadataTags)
            for part in visibleParts {
                appendResourceMetadataIfNeeded(
                    map: part.initializationMap,
                    encryption: part.encryption,
                    lines: &lines,
                    lastMap: &lastMap,
                    lastEncryption: &lastEncryption,
                    resolver: config.keyURLResolver,
                    configuration: config,
                    namespace: namespace
                )
                lines.append(renderPartLine(for: part, namespace: namespace, configuration: config))
            }

            if config.hideUntilBuffered && !bufferState.isReady(segment) {
                pendingSegments.append(segment)
                continue
            }

            appendResourceMetadataIfNeeded(
                map: segment.initializationMap,
                encryption: segment.encryption,
                lines: &lines,
                lastMap: &lastMap,
                lastEncryption: &lastEncryption,
                resolver: config.keyURLResolver,
                configuration: config,
                namespace: namespace
            )
            let durationString = String(format: "%.3f", segment.duration)
            lines.append("#EXTINF:\(durationString),")
            if let range = segment.byteRange {
                lines.append("#EXT-X-BYTERANGE:\(byteRangeString(for: range))")
            }
            lines.append(config.segmentURL(for: segment, namespace: namespace).absoluteString)
        }

        if lowLatencyEnabled {
            let trailingParts = visibleTrailingParts(
                mediaPlaylist.trailingParts,
                bufferState: bufferState,
                configuration: config
            )
            for part in trailingParts {
                appendResourceMetadataIfNeeded(
                    map: part.initializationMap,
                    encryption: part.encryption,
                    lines: &lines,
                    lastMap: &lastMap,
                    lastEncryption: &lastEncryption,
                    resolver: config.keyURLResolver,
                    configuration: config,
                    namespace: namespace
                )
                lines.append(renderPartLine(for: part, namespace: namespace, configuration: config))
            }
        }

        if config.hideUntilBuffered && !pendingSegments.isEmpty {
            logger.log(
                "Hiding \(pendingSegments.count) of \(mediaPlaylist.segments.count) segments until buffered.",
                level: .debug,
                category: .rewriter
            )
        }

        if lowLatencyEnabled {
            let hints: ArraySlice<HLSPreloadHint>
            if let count = config.lowLatencyOptions?.prefetchHintCount {
                hints = mediaPlaylist.preloadHints.prefix(max(0, count))
            } else {
                hints = mediaPlaylist.preloadHints[...]
            }
            lines.append(contentsOf: renderPreloadHints(
                hints,
                namespace: namespace,
                configuration: config
            ))
        }

        lines.append(contentsOf: renderRenditionReports(
            mediaPlaylist.renditionReports,
            resolver: config.renditionReportURLResolver
        ))

        if let lowLatency = config.lowLatencyOptions,
           lowLatency.enableDeltaUpdates,
           let skipCount = mediaPlaylist.skippedSegmentCount,
           skipCount > 0 {
            lines.append("#EXT-X-SKIP:SKIPPED-SEGMENTS=\(skipCount)")
        }

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
        if playlistControl?.canSkipDateRanges == true {
            attributes.append("CAN-SKIP-DATERANGES=YES")
        }
        if let holdBack = playlistControl?.holdBack {
            attributes.append("HOLD-BACK=\(String(format: "%.3f", holdBack))")
        }
        if let partHoldBack = options?.partHoldBack ?? playlistControl?.partHoldBack {
            attributes.append("PART-HOLD-BACK=\(String(format: "%.3f", partHoldBack))")
        }
        return attributes.isEmpty ? nil : attributes
    }

    private func visibleParts(
        for segment: HLSSegment,
        bufferState: BufferState,
        configuration: HLSRewriteConfiguration
    ) -> ArraySlice<HLSPartialSegment>? {
        guard !segment.parts.isEmpty else { return nil }
        let readyCount = bufferState.readyPartCount(for: segment.sequence)
        let shouldLimitToReady = configuration.hideUntilBuffered
        let limit = shouldLimitToReady ? readyCount : segment.parts.count
        guard limit > 0 else { return nil }
        return segment.parts.prefix(limit)
    }

    private func visibleTrailingParts(
        _ parts: [HLSPartialSegment],
        bufferState: BufferState,
        configuration: HLSRewriteConfiguration
    ) -> [HLSPartialSegment] {
        guard !parts.isEmpty else { return [] }
        if !configuration.hideUntilBuffered {
            return parts
        }
        return parts
            .filter { $0.partIndex < bufferState.readyPartCount(for: $0.parentSequence) }
    }

    private func renderPartLine(
        for part: HLSPartialSegment,
        namespace: String?,
        configuration: HLSRewriteConfiguration
    ) -> String {
        var attributes: [String] = []
        attributes.append("DURATION=\(String(format: "%.3f", part.duration))")
        let url = configuration.partialSegmentURL(for: part, namespace: namespace)
        attributes.append("URI=\"\(url.absoluteString)\"")
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
        _ hints: ArraySlice<HLSPreloadHint>,
        namespace: String?,
        configuration: HLSRewriteConfiguration
    ) -> [String] {
        hints.map { hint in
            var attributes: [String] = []
            attributes.append("TYPE=\(hint.type.rawValue)")
            let uri = configuration.preloadHintURL(for: hint, namespace: namespace)
            attributes.append("URI=\"\(uri.absoluteString)\"")
            if let start = hint.byteRangeStart {
                attributes.append("BYTERANGE-START=\(start)")
            }
            if let length = hint.byteRangeLength {
                attributes.append("BYTERANGE-LENGTH=\(length)")
            }
            return "#EXT-X-PRELOAD-HINT:\(attributes.joined(separator: ","))"
        }
    }

    private func renderRenditionReports(
        _ reports: [HLSRenditionReport],
        resolver: HLSRewriteConfiguration.RenditionReportURLResolver?
    ) -> [String] {
        reports.compactMap { report in
            guard let uri = resolver?(report) else { return nil }
            var attributes: [String] = []
            attributes.append("URI=\"\(uri.absoluteString)\"")
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

    private func appendResourceMetadataIfNeeded(
        map: MediaInitializationMap?,
        encryption: SegmentEncryption?,
        lines: inout [String],
        lastMap: inout MediaInitializationMap?,
        lastEncryption: inout SegmentEncryption?,
        resolver: HLSRewriteConfiguration.KeyURLResolver?,
        configuration: HLSRewriteConfiguration,
        namespace: String?
    ) {
        if map != lastMap {
            if let map {
                lines.append(renderMapLine(for: map, configuration: configuration, namespace: namespace))
            }
            lastMap = map
        }

        if encryption != lastEncryption {
            if let encryption,
               let keyLine = renderKeyLine(
                    prefix: "#EXT-X-KEY",
                    key: encryption.key,
                    initializationVector: encryption.initializationVector,
                    resolver: resolver
                ) {
                lines.append(keyLine)
            } else if lastEncryption != nil {
                lines.append("#EXT-X-KEY:METHOD=NONE")
            }
            lastEncryption = encryption
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

    private func renderMapLine(
        for map: MediaInitializationMap,
        configuration: HLSRewriteConfiguration,
        namespace: String?
    ) -> String {
        var attributes: [String] = []
        let localURL = configuration.initializationMapURL(for: map, namespace: namespace)
        attributes.append("URI=\"\(localURL.absoluteString)\"")
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
