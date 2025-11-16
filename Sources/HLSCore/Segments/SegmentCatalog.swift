import Foundation

public actor SegmentCatalog {
    public enum Namespace {
        public static let primary = "primary"
    }

    public struct Entry: Sendable {
        public let segment: HLSSegment
        public let namespace: String

        public init(segment: HLSSegment, namespace: String) {
            self.segment = segment
            self.namespace = namespace
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
            segmentsByKey[key] = Entry(segment: segment, namespace: namespace)
            keys.insert(key)
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
