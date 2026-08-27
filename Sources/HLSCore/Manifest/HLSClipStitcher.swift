import Foundation

/// Packager-supplied decoder compatibility for a directly stitched clip.
///
/// The stitcher deliberately does not infer this information from media bytes.
/// Values are normalized at initialization so compatibility is deterministic.
public struct HLSClipMediaSignature: Sendable, Hashable {
    public enum Container: String, Sendable, Hashable {
        case mpegTransportStream
        case fragmentedMP4
    }

    public struct Track: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case video
            case audio
            case subtitles
            case metadata
        }

        public let kind: Kind
        public let codec: String
        public let layout: String?

        public init(kind: Kind, codec: String, layout: String? = nil) {
            self.kind = kind
            self.codec = Self.normalized(codec)
            self.layout = layout.map(Self.normalized).flatMap { $0.isEmpty ? nil : $0 }
        }

        fileprivate var sortKey: String {
            "\(kind.rawValue):\(codec):\(layout ?? "")"
        }

        private static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public let container: Container
    public let codecs: [String]
    public let tracks: [Track]
    public let videoRange: String?
    public let segmentsAreIndependent: Bool

    public init(
        container: Container,
        codecs: [String],
        tracks: [Track],
        videoRange: String? = nil,
        segmentsAreIndependent: Bool
    ) {
        self.container = container
        self.codecs = Array(Set(codecs.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? nil : normalized
        })).sorted()
        self.tracks = Array(Set(tracks)).sorted { $0.sortKey < $1.sortKey }
        self.videoRange = videoRange.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }.flatMap { $0.isEmpty ? nil : $0 }
        self.segmentsAreIndependent = segmentsAreIndependent
    }

    public var containsVideo: Bool {
        tracks.contains { $0.kind == .video }
    }
}

/// One already-resolved media playlist and its trusted compatibility claim.
public struct HLSClip: Sendable, Hashable, Identifiable {
    public let id: String
    public let playlist: MediaPlaylist
    public let mediaSignature: HLSClipMediaSignature

    public init(
        id: String,
        playlist: MediaPlaylist,
        mediaSignature: HLSClipMediaSignature
    ) {
        self.id = id
        self.playlist = playlist
        self.mediaSignature = mediaSignature
    }
}

/// Stable, typed reasons why direct media-playlist concatenation is unsafe.
public enum HLSClipStitchingError: Error, Equatable, LocalizedError, Sendable {
    case noClips
    case emptyClipID(clipIndex: Int)
    case duplicateClipID(clipIndex: Int, id: String)
    case emptyPlaylist(clipIndex: Int)
    case invalidSegmentDuration(clipIndex: Int, segmentIndex: Int)
    case invalidMediaSequence(clipIndex: Int, sequence: Int)
    case sequenceArithmeticOverflow
    case unsupportedLiveOrLowLatencyPlaylist(clipIndex: Int)
    case unsupportedMasterOrRenditionTopology(clipIndex: Int)
    case unsupportedPlaylistMetadata(clipIndex: Int, tag: String)
    case interstitialMetadataRequiresInterstitialPath(clipIndex: Int, tag: String)
    case incompatibleMediaSignature(clipIndex: Int)
    case videoRequiresIndependentSegments(clipIndex: Int)
    case missingInitializationMap(clipIndex: Int, segmentIndex: Int)
    case encryptedInitializationMapRequiresExplicitIV(clipIndex: Int, segmentIndex: Int)
    case malformedProgramDateTime(clipIndex: Int, segmentIndex: Int, value: String)
    case ambiguousProgramDateTime(clipIndex: Int, segmentIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .noClips:
            "At least one HLS clip is required"
        case .emptyClipID(let clipIndex):
            "Clip \(clipIndex) has an empty stable ID"
        case .duplicateClipID(let clipIndex, let id):
            "Clip \(clipIndex) repeats stable ID: \(id)"
        case .emptyPlaylist(let clipIndex):
            "Clip \(clipIndex) has no complete media segments"
        case .invalidSegmentDuration(let clipIndex, let segmentIndex):
            "Clip \(clipIndex) segment \(segmentIndex) has an invalid duration"
        case .invalidMediaSequence(let clipIndex, let sequence):
            "Clip \(clipIndex) has an invalid media sequence: \(sequence)"
        case .sequenceArithmeticOverflow:
            "The stitched media sequence exceeds the supported integer range"
        case .unsupportedLiveOrLowLatencyPlaylist(let clipIndex):
            "Clip \(clipIndex) is live or carries low-latency reload state"
        case .unsupportedMasterOrRenditionTopology(let clipIndex):
            "Clip \(clipIndex) is a master playlist or carries rendition topology"
        case .unsupportedPlaylistMetadata(let clipIndex, let tag):
            "Clip \(clipIndex) contains unsupported playlist metadata: \(tag)"
        case .interstitialMetadataRequiresInterstitialPath(let clipIndex, let tag):
            "Clip \(clipIndex) contains interstitial/ad metadata that requires the interstitial path: \(tag)"
        case .incompatibleMediaSignature(let clipIndex):
            "Clip \(clipIndex) is not decoder-compatible with the first clip"
        case .videoRequiresIndependentSegments(let clipIndex):
            "Clip \(clipIndex) contains video without independent segment starts"
        case .missingInitializationMap(let clipIndex, let segmentIndex):
            "Fragmented MP4 clip \(clipIndex) segment \(segmentIndex) has no initialization map"
        case .encryptedInitializationMapRequiresExplicitIV(let clipIndex, let segmentIndex):
            "Clip \(clipIndex) segment \(segmentIndex) has an AES-128 encrypted map without an explicit IV"
        case .malformedProgramDateTime(let clipIndex, let segmentIndex, let value):
            "Clip \(clipIndex) segment \(segmentIndex) has malformed program date time: \(value)"
        case .ambiguousProgramDateTime(let clipIndex, let segmentIndex):
            "Clip \(clipIndex) segment \(segmentIndex) maps before the preceding program-date interval ends"
        }
    }
}

/// Validates and concatenates compatible finite media playlists without remuxing.
public struct HLSClipStitcher: Sendable {
    public init() {}

    public func stitch(_ clips: [HLSClip]) throws -> MediaPlaylist {
        guard !clips.isEmpty else { throw HLSClipStitchingError.noClips }
        try validateIdentities(clips)
        let expectedSignature = clips[0].mediaSignature
        var sessionKeys: [HLSKey] = []
        var seenSessionKeys: Set<HLSKey> = []
        var outputSegments: [HLSSegment] = []
        var mappedProgramDateCursor: Date?
        var outputVersion = 3

        for (clipIndex, clip) in clips.enumerated() {
            try validatePlaylist(clip, at: clipIndex, expectedSignature: expectedSignature)
            outputVersion = max(outputVersion, clip.playlist.protocolVersion ?? 3)
            for key in clip.playlist.sessionKeys where seenSessionKeys.insert(key).inserted {
                sessionKeys.append(key)
            }

            for (segmentIndex, segment) in clip.playlist.segments.enumerated() {
                try validateProgramDateTime(
                    in: segment,
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex,
                    cursor: &mappedProgramDateCursor
                )
                guard outputSegments.count < Int.max else {
                    throw HLSClipStitchingError.sequenceArithmeticOverflow
                }
                let sequence = outputSegments.count
                var metadata = segment.metadataTags
                if clipIndex > 0, segmentIndex == 0 {
                    metadata.removeAll { $0 == "#EXT-X-DISCONTINUITY" }
                    metadata.insert("#EXT-X-DISCONTINUITY", at: 0)
                }
                let encryption = try materializedEncryption(
                    segment.encryption,
                    originalSequence: segment.sequence,
                    clipIndex: clipIndex
                )
                outputSegments.append(HLSSegment(
                    url: segment.url,
                    duration: segment.duration,
                    sequence: sequence,
                    byteRange: segment.byteRange,
                    encryption: encryption,
                    initializationMap: segment.initializationMap,
                    metadataTags: metadata
                ))
                if segment.byteRange != nil { outputVersion = max(outputVersion, 4) }
                if segment.initializationMap != nil { outputVersion = max(outputVersion, 6) }
            }
        }

        let targetDuration = ceil(outputSegments.map(\.duration).max() ?? 0)
        return MediaPlaylist(
            protocolVersion: outputVersion,
            targetDuration: targetDuration,
            mediaSequence: 0,
            segments: outputSegments,
            isEndlist: true,
            sessionKeys: sessionKeys,
            independentSegments: clips.allSatisfy {
                $0.playlist.independentSegments && $0.mediaSignature.segmentsAreIndependent
            },
            playlistType: "VOD",
            discontinuitySequence: 0
        )
    }
}

private extension HLSClipStitcher {
    static let programDatePrefix = "#EXT-X-PROGRAM-DATE-TIME:"
    static let interstitialPrefixes = [
        "#EXT-X-DATERANGE:",
        "#EXT-X-CUE-OUT",
        "#EXT-X-CUE-IN",
        "#EXT-OATCLS-SCTE35:",
        "#EXT-X-SCTE35:",
        "#EXT-X-ASSET:",
        "#EXT-X-PLACEMENT-OPPORTUNITY:",
    ]

    func validateIdentities(_ clips: [HLSClip]) throws {
        var identifiers: Set<String> = []
        for (index, clip) in clips.enumerated() {
            let identifier = clip.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else {
                throw HLSClipStitchingError.emptyClipID(clipIndex: index)
            }
            guard identifiers.insert(identifier).inserted else {
                throw HLSClipStitchingError.duplicateClipID(clipIndex: index, id: identifier)
            }
        }
    }

    func validatePlaylist(
        _ clip: HLSClip,
        at clipIndex: Int,
        expectedSignature: HLSClipMediaSignature
    ) throws {
        let playlist = clip.playlist
        guard clip.mediaSignature == expectedSignature else {
            throw HLSClipStitchingError.incompatibleMediaSignature(clipIndex: clipIndex)
        }
        guard !playlist.segments.isEmpty else {
            throw HLSClipStitchingError.emptyPlaylist(clipIndex: clipIndex)
        }
        guard playlist.mediaSequence >= 0 else {
            throw HLSClipStitchingError.invalidMediaSequence(
                clipIndex: clipIndex,
                sequence: playlist.mediaSequence
            )
        }
        guard playlist.isEndlist,
              playlist.playlistType.map({ $0.caseInsensitiveCompare("VOD") == .orderedSame }) ?? true,
              playlist.partTargetDuration == nil,
              playlist.serverControl == nil,
              playlist.preloadHints.isEmpty,
              playlist.renditionReports.isEmpty,
              playlist.skippedSegmentCount == nil,
              playlist.trailingParts.isEmpty,
              playlist.segments.allSatisfy({ $0.parts.isEmpty })
        else {
            throw HLSClipStitchingError.unsupportedLiveOrLowLatencyPlaylist(clipIndex: clipIndex)
        }
        if let startTag = playlist.startTag {
            throw HLSClipStitchingError.unsupportedPlaylistMetadata(
                clipIndex: clipIndex,
                tag: startTag
            )
        }
        if let tag = playlist.passthroughTags.first {
            if Self.isInterstitial(tag) {
                throw HLSClipStitchingError.interstitialMetadataRequiresInterstitialPath(
                    clipIndex: clipIndex,
                    tag: tag
                )
            }
            throw HLSClipStitchingError.unsupportedPlaylistMetadata(
                clipIndex: clipIndex,
                tag: tag
            )
        }
        if let tag = playlist.segments
            .flatMap(\.metadataTags)
            .first(where: Self.isInterstitial) {
            throw HLSClipStitchingError.interstitialMetadataRequiresInterstitialPath(
                clipIndex: clipIndex,
                tag: tag
            )
        }
        if expectedSignature.containsVideo,
           (!expectedSignature.segmentsAreIndependent || !playlist.independentSegments) {
            throw HLSClipStitchingError.videoRequiresIndependentSegments(clipIndex: clipIndex)
        }

        for (segmentIndex, segment) in playlist.segments.enumerated() {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSClipStitchingError.invalidSegmentDuration(
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex
                )
            }
            guard segment.sequence >= 0 else {
                throw HLSClipStitchingError.invalidMediaSequence(
                    clipIndex: clipIndex,
                    sequence: segment.sequence
                )
            }
            if expectedSignature.container == .fragmentedMP4,
               segment.initializationMap == nil {
                throw HLSClipStitchingError.missingInitializationMap(
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex
                )
            }
            if let mapEncryption = segment.initializationMap?.encryption,
               mapEncryption.key.method == .aes128,
               mapEncryption.initializationVector == nil {
                throw HLSClipStitchingError.encryptedInitializationMapRequiresExplicitIV(
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex
                )
            }
        }
    }

    func validateProgramDateTime(
        in segment: HLSSegment,
        clipIndex: Int,
        segmentIndex: Int,
        cursor: inout Date?
    ) throws {
        let tags = segment.metadataTags.filter { $0.hasPrefix(Self.programDatePrefix) }
        guard tags.count <= 1 else {
            throw HLSClipStitchingError.ambiguousProgramDateTime(
                clipIndex: clipIndex,
                segmentIndex: segmentIndex
            )
        }
        if let tag = tags.first {
            let value = String(tag.dropFirst(Self.programDatePrefix.count))
            guard let date = Self.parseProgramDate(value) else {
                throw HLSClipStitchingError.malformedProgramDateTime(
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex,
                    value: value
                )
            }
            if let cursor, date < cursor {
                throw HLSClipStitchingError.ambiguousProgramDateTime(
                    clipIndex: clipIndex,
                    segmentIndex: segmentIndex
                )
            }
            cursor = date
        }
        if let current = cursor {
            cursor = current.addingTimeInterval(segment.duration)
        }
    }

    func materializedEncryption(
        _ encryption: SegmentEncryption?,
        originalSequence: Int,
        clipIndex: Int
    ) throws -> SegmentEncryption? {
        guard let encryption, encryption.key.method == .aes128,
              encryption.initializationVector == nil
        else {
            return encryption
        }
        guard originalSequence >= 0 else {
            throw HLSClipStitchingError.invalidMediaSequence(
                clipIndex: clipIndex,
                sequence: originalSequence
            )
        }
        return SegmentEncryption(
            key: encryption.key,
            initializationVector: String(format: "0x%032llx", UInt64(originalSequence))
        )
    }

    static func isInterstitial(_ tag: String) -> Bool {
        interstitialPrefixes.contains { prefix in
            prefix.hasSuffix(":") ? tag.hasPrefix(prefix) : tag == prefix || tag.hasPrefix(prefix + ":")
        }
    }

    static func parseProgramDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }
}
