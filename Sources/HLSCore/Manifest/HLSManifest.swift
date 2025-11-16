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

public struct HLSSegment: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let duration: TimeInterval
    public let sequence: Int
    public let byteRange: ClosedRange<Int>?
    public let encryption: SegmentEncryption?
    public let initializationMap: MediaInitializationMap?

    public init(
        url: URL,
        duration: TimeInterval,
        sequence: Int,
        byteRange: ClosedRange<Int>? = nil,
        encryption: SegmentEncryption? = nil,
        initializationMap: MediaInitializationMap? = nil
    ) {
        self.url = url
        self.duration = duration
        self.sequence = sequence
        self.byteRange = byteRange
        self.encryption = encryption
        self.initializationMap = initializationMap
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

    public init(
        targetDuration: TimeInterval?,
        mediaSequence: Int = 0,
        segments: [HLSSegment],
        isEndlist: Bool = false,
        sessionKeys: [HLSKey] = []
    ) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.segments = segments
        self.isEndlist = isEndlist
        self.sessionKeys = sessionKeys
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
    var requiresURI: Bool {
        switch self {
        case .audio, .subtitles:
            return true
        case .closedCaptions:
            return false
        }
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
