import Foundation

public protocol SegmentSource: Sendable {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data
    func fetchPartialSegment(_ segment: HLSPartialSegment) async throws -> Data
}

public protocol Caching: Sendable {
    func get(_ key: String) async -> Data?
    func put(_ data: Data, for key: String) async
}

public extension SegmentSource {
    func fetchPartialSegment(_ segment: HLSPartialSegment) async throws -> Data {
        try await fetchSegment(segment.asSegment())
    }
}
