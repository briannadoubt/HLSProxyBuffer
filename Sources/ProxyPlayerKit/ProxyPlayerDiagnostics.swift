import HLSCore

public struct ProxyPlayerDiagnostics: Sendable {
    public struct KeyStatus: Sendable, Equatable, Hashable {
        public let method: HLSKey.Method
        public let uriHash: String
        public let isSessionKey: Bool

        public init(method: HLSKey.Method, uriHash: String, isSessionKey: Bool) {
            self.method = method
            self.uriHash = uriHash
            self.isSessionKey = isSessionKey
        }
    }

    public var onPlaylistServed: (@Sendable () -> Void)?
    public var onSegmentServed: (@Sendable (Int) -> Void)?
    public var onPlaylistRefreshed: (@Sendable (PlaylistRefreshController.Metrics) -> Void)?
    public var onQualityChanged: (@Sendable (VariantPlaylist) -> Void)?
    public var onRenditionChanged: (@Sendable (HLSManifest.Rendition.Kind, HLSManifest.Rendition?) -> Void)?
    public var onKeyMetadataChanged: (@Sendable ([KeyStatus]) -> Void)?

    public init(
        onPlaylistServed: (@Sendable () -> Void)? = nil,
        onSegmentServed: (@Sendable (Int) -> Void)? = nil,
        onPlaylistRefreshed: (@Sendable (PlaylistRefreshController.Metrics) -> Void)? = nil,
        onQualityChanged: (@Sendable (VariantPlaylist) -> Void)? = nil,
        onRenditionChanged: (@Sendable (HLSManifest.Rendition.Kind, HLSManifest.Rendition?) -> Void)? = nil,
        onKeyMetadataChanged: (@Sendable ([KeyStatus]) -> Void)? = nil
    ) {
        self.onPlaylistServed = onPlaylistServed
        self.onSegmentServed = onSegmentServed
        self.onPlaylistRefreshed = onPlaylistRefreshed
        self.onQualityChanged = onQualityChanged
        self.onRenditionChanged = onRenditionChanged
        self.onKeyMetadataChanged = onKeyMetadataChanged
    }
}
