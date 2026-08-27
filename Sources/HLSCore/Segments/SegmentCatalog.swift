import Foundation

public actor SegmentCatalog {
    public enum Namespace {
        public static let primary = "primary"
    }

    public struct Entry: Sendable {
        public enum Payload: Sendable {
            case segment(HLSSegment)
            case part(HLSPartialSegment)
            case initializationMap(MediaInitializationMap)
            case preloadHint(HLSPreloadHint)
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

        public var initializationMap: MediaInitializationMap? {
            if case .initializationMap(let value) = payload { return value }
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

            if let map = segment.initializationMap {
                let mapKey = SegmentIdentity.key(
                    for: map,
                    namespace: namespace == Namespace.primary ? nil : namespace
                )
                segmentsByKey[mapKey] = Entry(payload: .initializationMap(map), namespace: namespace)
                keys.insert(mapKey)
            }

            for part in segment.parts {
                let partKey = SegmentIdentity.key(
                    for: part,
                    namespace: namespace == Namespace.primary ? nil : namespace
                )
                segmentsByKey[partKey] = Entry(payload: .part(part), namespace: namespace)
                keys.insert(partKey)
                if let map = part.initializationMap {
                    let mapKey = SegmentIdentity.key(
                        for: map,
                        namespace: namespace == Namespace.primary ? nil : namespace
                    )
                    segmentsByKey[mapKey] = Entry(payload: .initializationMap(map), namespace: namespace)
                    keys.insert(mapKey)
                }
            }
        }
        for part in playlist.trailingParts {
            let partKey = SegmentIdentity.key(
                for: part,
                namespace: namespace == Namespace.primary ? nil : namespace
            )
            segmentsByKey[partKey] = Entry(payload: .part(part), namespace: namespace)
            keys.insert(partKey)
        }
        for hint in playlist.preloadHints {
            let hintKey = SegmentIdentity.key(
                for: hint,
                namespace: namespace == Namespace.primary ? nil : namespace
            )
            segmentsByKey[hintKey] = Entry(payload: .preloadHint(hint), namespace: namespace)
            keys.insert(hintKey)
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
