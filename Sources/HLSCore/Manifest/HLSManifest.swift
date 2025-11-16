import Foundation

public enum HLSManifestKind: Equatable, Sendable {
    case master
    case media
}

public struct HLSSegment: Sendable, Hashable, Identifiable, Codable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let duration: TimeInterval
    public let sequence: Int
    public let byteRange: ClosedRange<Int>?

    public init(url: URL, duration: TimeInterval, sequence: Int, byteRange: ClosedRange<Int>? = nil) {
        self.url = url
        self.duration = duration
        self.sequence = sequence
        self.byteRange = byteRange
    }
}

public struct VariantPlaylist: Sendable, Hashable, Identifiable {
    public struct Attributes: Sendable, Hashable {
        public let bandwidth: Int?
        public let resolution: String?
        public let codecs: String?

        public init(bandwidth: Int? = nil, resolution: String? = nil, codecs: String? = nil) {
            self.bandwidth = bandwidth
            self.resolution = resolution
            self.codecs = codecs
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

    public init(targetDuration: TimeInterval?, mediaSequence: Int = 0, segments: [HLSSegment]) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.segments = segments
    }
}

public struct HLSManifest: Sendable, Hashable {
    public let kind: HLSManifestKind
    public let variants: [VariantPlaylist]
    public let mediaPlaylist: MediaPlaylist?
    public let originalText: String

    public init(kind: HLSManifestKind, variants: [VariantPlaylist] = [], mediaPlaylist: MediaPlaylist?, originalText: String) {
        self.kind = kind
        self.variants = variants
        self.mediaPlaylist = mediaPlaylist
        self.originalText = originalText
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
