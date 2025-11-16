import Foundation
import HLSCore

public actor PlaylistStore {
    private var playlist: String = "#EXTM3U\n#EXT-X-ENDLIST"

    public init() {}

    public func update(_ text: String) {
        playlist = text
    }

    public func snapshot() -> String {
        playlist
    }
}

public struct PlaylistHandler: Sendable {
    private let store: PlaylistStore
    private let onServe: (@Sendable () -> Void)?

    public init(store: PlaylistStore, onServe: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.onServe = onServe
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            _ = request
            let text = await store.snapshot()
            onServe?()
            return HTTPResponse.text(text)
        }
    }
}
