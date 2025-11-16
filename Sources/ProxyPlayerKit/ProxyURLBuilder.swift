import Foundation

public struct ProxyURLBuilder {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func playlistURL(filename: String = "playlist.m3u8") -> URL {
        baseURL.appendingPathComponent(filename)
    }

    public func segmentURL(sequence: Int, prefix: String = "segments") -> URL {
        baseURL
            .appendingPathComponent(prefix)
            .appendingPathComponent(String(sequence))
    }
}
