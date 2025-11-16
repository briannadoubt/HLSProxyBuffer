import Foundation

public protocol HLSManifestSource: Sendable {
    func fetchManifest() async throws -> String
}
