public struct ProxyPlayerDiagnostics: Sendable {
    public var onPlaylistServed: (@Sendable () -> Void)?
    public var onSegmentServed: (@Sendable (Int) -> Void)?

    public init(
        onPlaylistServed: (@Sendable () -> Void)? = nil,
        onSegmentServed: (@Sendable (Int) -> Void)? = nil
    ) {
        self.onPlaylistServed = onPlaylistServed
        self.onSegmentServed = onSegmentServed
    }
}
