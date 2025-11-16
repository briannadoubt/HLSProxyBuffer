import Foundation

public struct PlayerState: Sendable, Equatable {
    public enum Status: Equatable, Sendable {
        case idle
        case buffering
        case ready
        case failed(String)
    }

    public let status: Status
    public let bufferDepthSeconds: TimeInterval
    public let qualityDescription: String

    public init(
        status: Status = .idle,
        bufferDepthSeconds: TimeInterval = 0,
        qualityDescription: String = "auto"
    ) {
        self.status = status
        self.bufferDepthSeconds = bufferDepthSeconds
        self.qualityDescription = qualityDescription
    }
}
