import Foundation

public protocol SegmentSource: Sendable {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data
}

public protocol Caching: Sendable {
    func get(_ key: String) async -> Data?
    func put(_ data: Data, for key: String) async
}
