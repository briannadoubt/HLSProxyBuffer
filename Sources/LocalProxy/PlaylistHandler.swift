import Foundation
import HLSCore

public actor PlaylistStore {
    public enum Identifier {
        public static let master = "master"
        public static let primaryVariant = "variant-primary"

        public static func rendition(_ name: String) -> String {
            "rendition-\(name)"
        }
    }

    private var playlists: [String: String]
    private let defaultPlaylist: String

    public init(defaultPlaylist: String = "#EXTM3U\n#EXT-X-ENDLIST") {
        self.defaultPlaylist = defaultPlaylist
        self.playlists = [:]
    }

    public func update(_ text: String, for identifier: String = Identifier.master) {
        playlists[identifier] = text
    }

    public func snapshot(for identifier: String = Identifier.master) -> String {
        playlists[identifier] ?? defaultPlaylist
    }

    public func remove(_ identifier: String) {
        playlists.removeValue(forKey: identifier)
    }
}

public struct PlaylistHandler: Sendable {
    private let store: PlaylistStore
    private let identifier: String
    private let onServe: (@Sendable () -> Void)?

    public init(
        store: PlaylistStore,
        identifier: String = PlaylistStore.Identifier.master,
        onServe: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.identifier = identifier
        self.onServe = onServe
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            _ = request
            let text = await store.snapshot(for: identifier)
            onServe?()
            return HTTPResponse.text(text)
        }
    }
}

public struct RenditionPlaylistHandler: Sendable {
    private let store: PlaylistStore

    public init(store: PlaylistStore) {
        self.store = store
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            guard let last = request.path.split(separator: "/").last else {
                return HTTPResponse(status: .notFound)
            }
            let identifier = sanitizedIdentifier(from: String(last))
            let text = await store.snapshot(for: PlaylistStore.Identifier.rendition(identifier))
            return HTTPResponse.text(text)
        }
    }

    private func sanitizedIdentifier(from component: String) -> String {
        component
            .replacingOccurrences(of: ".m3u8", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
