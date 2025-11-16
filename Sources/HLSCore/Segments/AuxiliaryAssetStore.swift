import Foundation

public enum AuxiliaryAssetType: String, CaseIterable, Sendable {
    case audio
    case subtitles
    case keys
}

public actor AuxiliaryAssetStore {
    private var storage: [AuxiliaryAssetType: [String: Data]] = [:]

    public init() {}

    public func register(
        data: Data,
        identifier: String,
        type: AuxiliaryAssetType
    ) {
        var bucket = storage[type] ?? [:]
        bucket[identifier] = data
        storage[type] = bucket
    }

    public func data(for identifier: String, type: AuxiliaryAssetType) -> Data? {
        storage[type]?[identifier]
    }
}
