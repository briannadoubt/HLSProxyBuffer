import Foundation

public actor SegmentCatalog {
    public enum Namespace {
        public static let primary = "primary"
    }

    public struct Entry: Sendable {
        public enum Payload: Sendable {
            case segment(HLSSegment)
            case part(HLSPartialSegment)
        }

        public let payload: Payload
        public let namespace: String

        public init(payload: Payload, namespace: String) {
            self.payload = payload
            self.namespace = namespace
        }

        public var segment: HLSSegment? {
            if case .segment(let value) = payload { return value }
            return nil
        }

        public var part: HLSPartialSegment? {
            if case .part(let value) = payload { return value }
            return nil
        }
    }

    private var playlists: [String: MediaPlaylist] = [:]
    private var segmentsByKey: [String: Entry] = [:]
    private var keysByNamespace: [String: Set<String>] = [:]

    public init() {}

    public func update(with playlist: MediaPlaylist, namespace: String = Namespace.primary) {
        playlists[namespace] = playlist
        if let existingKeys = keysByNamespace[namespace] {
            for key in existingKeys {
                segmentsByKey.removeValue(forKey: key)
            }
        }

        var keys: Set<String> = []
        for segment in playlist.segments {
            let key = SegmentIdentity.key(
                for: segment,
                namespace: namespace == Namespace.primary ? nil : namespace
            )
            segmentsByKey[key] = Entry(payload: .segment(segment), namespace: namespace)
            keys.insert(key)

            for part in segment.parts {
                let partKey = SegmentIdentity.key(
                    for: part,
                    namespace: namespace == Namespace.primary ? nil : namespace
                )
                segmentsByKey[partKey] = Entry(payload: .part(part), namespace: namespace)
                keys.insert(partKey)
            }
        }
        keysByNamespace[namespace] = keys
    }

    public func segmentEntry(forKey key: String) -> Entry? {
        segmentsByKey[key]
    }

    public func playlist(for namespace: String = Namespace.primary) -> MediaPlaylist? {
        playlists[namespace]
    }

    public func removeEntries(for namespace: String) {
        playlists.removeValue(forKey: namespace)
        guard let keys = keysByNamespace.removeValue(forKey: namespace) else { return }
        for key in keys {
            segmentsByKey.removeValue(forKey: key)
        }
    }
}
