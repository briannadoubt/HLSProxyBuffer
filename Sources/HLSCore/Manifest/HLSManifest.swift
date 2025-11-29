import Foundation

public enum HLSManifestKind: Equatable, Sendable {
    case master
    case media
}

public struct HLSKey: Sendable, Hashable, Codable {
    public enum Method: String, Sendable, Codable {
        case none = "NONE"
        case aes128 = "AES-128"
        case sampleAES = "SAMPLE-AES"
        case sampleAESCTR = "SAMPLE-AES-CTR"
    }

    public let method: Method
    public let uri: URL?
    public let keyFormat: String?
    public let keyFormatVersions: [String]
    public let isSessionKey: Bool

    public init(
        method: Method,
        uri: URL?,
        keyFormat: String? = nil,
        keyFormatVersions: [String] = [],
        isSessionKey: Bool = false
    ) {
        self.method = method
        self.uri = uri
        self.keyFormat = keyFormat
        self.keyFormatVersions = keyFormatVersions
        self.isSessionKey = isSessionKey
    }
}

public struct SegmentEncryption: Sendable, Hashable, Codable {
    public let key: HLSKey
    public let initializationVector: String?

    public init(key: HLSKey, initializationVector: String? = nil) {
        self.key = key
        self.initializationVector = initializationVector
    }
}

public struct MediaInitializationMap: Sendable, Hashable, Codable {
    public let uri: URL
    public let byteRange: ClosedRange<Int>?

    public init(uri: URL, byteRange: ClosedRange<Int>? = nil) {
        self.uri = uri
        self.byteRange = byteRange
    }
}

public struct HLSPartialSegment: Sendable, Hashable, Identifiable, Codable {
    public var id: String { "part-\(parentSequence)-\(partIndex)" }
    public let parentSequence: Int
    public let partIndex: Int
    public let duration: TimeInterval
    public let url: URL
    public let byteRange: ClosedRange<Int>?
    public let isIndependent: Bool
    public let isGap: Bool
    public let encryption: SegmentEncryption?
    public let initializationMap: MediaInitializationMap?

    public init(
        parentSequence: Int,
        partIndex: Int,
        duration: TimeInterval,
        url: URL,
        byteRange: ClosedRange<Int>? = nil,
        isIndependent: Bool = false,
        isGap: Bool = false,
        encryption: SegmentEncryption? = nil,
        initializationMap: MediaInitializationMap? = nil
    ) {
        self.parentSequence = parentSequence
        self.partIndex = partIndex
        self.duration = duration
        self.url = url
        self.byteRange = byteRange
        self.isIndependent = isIndependent
        self.isGap = isGap
        self.encryption = encryption
        self.initializationMap = initializationMap
    }

    public func asSegment() -> HLSSegment {
        HLSSegment(
            url: url,
            duration: duration,
            sequence: parentSequence,
            byteRange: byteRange,
            encryption: encryption,
            initializationMap: initializationMap,
            parts: []
        )
    }
}

public struct HLSPreloadHint: Sendable, Hashable, Codable {
    public enum HintType: String, Sendable, Codable {
        case part = "PART"
        case map = "MAP"
    }

    public let type: HintType
    public let uri: URL
    public let byteRangeStart: Int?
    public let byteRangeLength: Int?
    public let sequence: Int
    public let partIndex: Int?

    public init(
        type: HintType,
        uri: URL,
        byteRangeStart: Int? = nil,
        byteRangeLength: Int? = nil,
        sequence: Int,
        partIndex: Int? = nil
    ) {
        self.type = type
        self.uri = uri
        self.byteRangeStart = byteRangeStart
        self.byteRangeLength = byteRangeLength
        self.sequence = sequence
        self.partIndex = partIndex
    }

    public var byteRange: ClosedRange<Int>? {
        guard let start = byteRangeStart, let length = byteRangeLength else { return nil }
        return start...(start + length - 1)
    }
}

public struct HLSRenditionReport: Sendable, Hashable, Codable {
    public let uri: URL
    public let lastMediaSequence: Int?
    public let lastPartIndex: Int?
    public let averageBandwidth: Int?

    public init(
        uri: URL,
        lastMediaSequence: Int? = nil,
        lastPartIndex: Int? = nil,
        averageBandwidth: Int? = nil
    ) {
        self.uri = uri
        self.lastMediaSequence = lastMediaSequence
        self.lastPartIndex = lastPartIndex
        self.averageBandwidth = averageBandwidth
    }
}

public struct HLSServerControl: Sendable, Hashable, Codable {
    public let canSkipUntil: TimeInterval?
    public let canBlockReload: Bool
    public let canSkipDateRanges: Bool
    public let canPrefetch: Bool
    public let holdBack: TimeInterval?
    public let partHoldBack: TimeInterval?
    public let partTarget: TimeInterval?

    public init(
        canSkipUntil: TimeInterval? = nil,
        canBlockReload: Bool = false,
        canSkipDateRanges: Bool = false,
        canPrefetch: Bool = false,
        holdBack: TimeInterval? = nil,
        partHoldBack: TimeInterval? = nil,
        partTarget: TimeInterval? = nil
    ) {
        self.canSkipUntil = canSkipUntil
        self.canBlockReload = canBlockReload
        self.canSkipDateRanges = canSkipDateRanges
        self.canPrefetch = canPrefetch
        self.holdBack = holdBack
        self.partHoldBack = partHoldBack
        self.partTarget = partTarget
    }
}

public struct HLSSegment: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let duration: TimeInterval
    public let sequence: Int
    public let byteRange: ClosedRange<Int>?
    public let encryption: SegmentEncryption?
    public let initializationMap: MediaInitializationMap?
    public let parts: [HLSPartialSegment]

    public init(
        url: URL,
        duration: TimeInterval,
        sequence: Int,
        byteRange: ClosedRange<Int>? = nil,
        encryption: SegmentEncryption? = nil,
        initializationMap: MediaInitializationMap? = nil,
        parts: [HLSPartialSegment] = []
    ) {
        self.url = url
        self.duration = duration
        self.sequence = sequence
        self.byteRange = byteRange
        self.encryption = encryption
        self.initializationMap = initializationMap
        self.parts = parts
    }
}

public struct VariantPlaylist: Sendable, Hashable, Identifiable {
    public struct Resolution: Sendable, Hashable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct Attributes: Sendable, Hashable {
        public let bandwidth: Int?
        public let averageBandwidth: Int?
        public let frameRate: Double?
        public let resolution: Resolution?
        public let codecs: String?
        public let audioGroupId: String?
        public let subtitleGroupId: String?
        public let closedCaptionGroupId: String?

        public init(
            bandwidth: Int? = nil,
            averageBandwidth: Int? = nil,
            frameRate: Double? = nil,
            resolution: Resolution? = nil,
            codecs: String? = nil,
            audioGroupId: String? = nil,
            subtitleGroupId: String? = nil,
            closedCaptionGroupId: String? = nil
        ) {
            self.bandwidth = bandwidth
            self.averageBandwidth = averageBandwidth
            self.frameRate = frameRate
            self.resolution = resolution
            self.codecs = codecs
            self.audioGroupId = audioGroupId
            self.subtitleGroupId = subtitleGroupId
            self.closedCaptionGroupId = closedCaptionGroupId
        }
    }

    public var id: String { url.absoluteString }
    public let url: URL
    public let attributes: Attributes

    public init(url: URL, attributes: Attributes) {
        self.url = url
        self.attributes = attributes
    }
}

public struct MediaPlaylist: Sendable, Hashable {
    public let targetDuration: TimeInterval?
    public let mediaSequence: Int
    public let segments: [HLSSegment]
    public let isEndlist: Bool
    public let sessionKeys: [HLSKey]
    public let partTargetDuration: TimeInterval?
    public let serverControl: HLSServerControl?
    public let preloadHints: [HLSPreloadHint]
    public let renditionReports: [HLSRenditionReport]
    public let skippedSegmentCount: Int?

    public init(
        targetDuration: TimeInterval?,
        mediaSequence: Int = 0,
        segments: [HLSSegment],
        isEndlist: Bool = false,
        sessionKeys: [HLSKey] = [],
        partTargetDuration: TimeInterval? = nil,
        serverControl: HLSServerControl? = nil,
        preloadHints: [HLSPreloadHint] = [],
        renditionReports: [HLSRenditionReport] = [],
        skippedSegmentCount: Int? = nil
    ) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.segments = segments
        self.isEndlist = isEndlist
        self.sessionKeys = sessionKeys
        self.partTargetDuration = partTargetDuration
        self.serverControl = serverControl
        self.preloadHints = preloadHints
        self.renditionReports = renditionReports
        self.skippedSegmentCount = skippedSegmentCount
    }
}

public struct HLSManifest: Sendable, Hashable {
    public struct Rendition: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable {
            case audio
            case subtitles
            case closedCaptions
        }

        public var id: String {
            let raw = "\(type.rawValue)-\(groupId)-\(name)"
            return raw
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined(separator: "-")
        }

        public let type: Kind
        public let groupId: String
        public let name: String
        public let language: String?
        public let isDefault: Bool
        public let isAutoSelect: Bool
        public let isForced: Bool
        public let characteristics: [String]
        public let uri: URL?
        public let instreamId: String?

        public init(
            type: Kind,
            groupId: String,
            name: String,
            language: String? = nil,
            isDefault: Bool = false,
            isAutoSelect: Bool = false,
            isForced: Bool = false,
            characteristics: [String] = [],
            uri: URL?,
            instreamId: String? = nil
        ) {
            self.type = type
            self.groupId = groupId
            self.name = name
            self.language = language
            self.isDefault = isDefault
            self.isAutoSelect = isAutoSelect
            self.isForced = isForced
            self.characteristics = characteristics
            self.uri = uri
            self.instreamId = instreamId
        }
    }

    public let kind: HLSManifestKind
    public let variants: [VariantPlaylist]
    public let mediaPlaylist: MediaPlaylist?
    public let renditions: [Rendition]
    public let sessionKeys: [HLSKey]
    public let originalText: String

    public init(
        kind: HLSManifestKind,
        variants: [VariantPlaylist] = [],
        mediaPlaylist: MediaPlaylist?,
        renditions: [Rendition] = [],
        originalText: String,
        sessionKeys: [HLSKey] = []
    ) {
        self.kind = kind
        self.variants = variants
        self.mediaPlaylist = mediaPlaylist
        self.renditions = renditions
        self.sessionKeys = sessionKeys
        self.originalText = originalText
    }
}

public extension HLSManifest.Rendition.Kind {
    /// Per RFC 8216, URI is optional for AUDIO and SUBTITLES (omitted when media is muxed in the main stream).
    /// CLOSED-CAPTIONS never has a URI (uses INSTREAM-ID instead).
    var requiresURI: Bool {
        false
    }

    var requiresInstreamId: Bool {
        switch self {
        case .closedCaptions:
            return true
        case .audio, .subtitles:
            return false
        }
    }
}

public struct QualityProfile: Sendable, Equatable, Hashable {
    public let name: String
    public let minimumBandwidth: Int?
    public let maximumBandwidth: Int?

    public init(name: String, minimumBandwidth: Int? = nil, maximumBandwidth: Int? = nil) {
        self.name = name
        self.minimumBandwidth = minimumBandwidth
        self.maximumBandwidth = maximumBandwidth
    }

    public func matches(bandwidth: Int?) -> Bool {
        guard let bandwidth else { return minimumBandwidth == nil && maximumBandwidth == nil }
        if let minimumBandwidth, bandwidth < minimumBandwidth { return false }
        if let maximumBandwidth, bandwidth > maximumBandwidth { return false }
        return true
    }
}
