import Dispatch
import Foundation

/// Versioned, privacy-bounded analytics values shared by the feed engine,
/// local proxy, origin transport, and AVFoundation adapters.
public enum PlaybackAnalytics {
    public struct SchemaVersion: Equatable, Hashable, Codable, Sendable {
        public static let current = Self(major: 1, minor: 0)
        public static let supportedMajor: UInt16 = 1

        public let major: UInt16
        public let minor: UInt16

        public init(major: UInt16, minor: UInt16) {
            self.major = major
            self.minor = minor
        }
    }

    public enum ContractError: Error, Equatable, Sendable {
        case unsupportedSchemaMajor(UInt16)
        case tooManyDimensionKeys(limit: Int)
        case invalidDimensionKey
        case unknownDimensionKey
        case tooManyAllowedValues(key: String, limit: Int)
        case invalidAllowedValue(key: String)
        case invalidMeasurementName
        case invalidMeasurementValue
        case tooManyMeasurements(limit: Int)
        case duplicateMeasurement(String)
    }

    /// A generated identifier for one analytics collection session.
    public struct SessionID: Hashable, Codable, Sendable {
        private let value: UUID

        public init() {
            value = UUID()
        }

        public init?(encodedValue: String) {
            guard let value = UUID(uuidString: encodedValue) else { return nil }
            self.value = value
        }

        public var encodedValue: String { value.uuidString.lowercased() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedValue = try container.decode(String.self)
            guard let value = UUID(uuidString: encodedValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an opaque UUID analytics identifier."
                )
            }
            self.value = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(encodedValue)
        }
    }

    /// A generated identifier for a single playback attempt.
    public struct PlaybackID: Hashable, Codable, Sendable {
        private let value: UUID

        public init() {
            value = UUID()
        }

        public init?(encodedValue: String) {
            guard let value = UUID(uuidString: encodedValue) else { return nil }
            self.value = value
        }

        public var encodedValue: String { value.uuidString.lowercased() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedValue = try container.decode(String.self)
            guard let value = UUID(uuidString: encodedValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an opaque UUID analytics identifier."
                )
            }
            self.value = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(encodedValue)
        }
    }

    /// A generated analytics identity for a media item. This is deliberately
    /// distinct from application feed identifiers and never stores a URL.
    public struct ItemID: Hashable, Codable, Sendable {
        private let value: UUID

        public init() {
            value = UUID()
        }

        public init?(encodedValue: String) {
            guard let value = UUID(uuidString: encodedValue) else { return nil }
            self.value = value
        }

        public var encodedValue: String { value.uuidString.lowercased() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedValue = try container.decode(String.self)
            guard let value = UUID(uuidString: encodedValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an opaque UUID analytics identifier."
                )
            }
            self.value = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(encodedValue)
        }
    }

    /// An idempotency key for one event or terminal summary.
    public struct RecordID: Hashable, Codable, Sendable {
        private let value: UUID

        public init() {
            value = UUID()
        }

        public init?(encodedValue: String) {
            guard let value = UUID(uuidString: encodedValue) else { return nil }
            self.value = value
        }

        public var encodedValue: String { value.uuidString.lowercased() }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedValue = try container.decode(String.self)
            guard let value = UUID(uuidString: encodedValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an opaque UUID analytics identifier."
                )
            }
            self.value = value
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(encodedValue)
        }
    }

    public struct Correlation: Equatable, Hashable, Codable, Sendable {
        public let sessionID: SessionID
        public let playbackID: PlaybackID
        public let itemID: ItemID

        public init(sessionID: SessionID, playbackID: PlaybackID, itemID: ItemID) {
            self.sessionID = sessionID
            self.playbackID = playbackID
            self.itemID = itemID
        }
    }

    /// One wall-clock anchor per session. Events store only monotonic elapsed
    /// time from this anchor, avoiding wall-clock jumps in duration metrics.
    public struct ClockAnchor: Equatable, Hashable, Codable, Sendable {
        public let unixMilliseconds: Int64

        public init(unixMilliseconds: Int64) {
            self.unixMilliseconds = unixMilliseconds
        }
    }

    public struct Timestamp: Equatable, Hashable, Codable, Sendable {
        public let anchor: ClockAnchor
        public let elapsedNanoseconds: UInt64

        public init(anchor: ClockAnchor, elapsedNanoseconds: UInt64) {
            self.anchor = anchor
            self.elapsedNanoseconds = elapsedNanoseconds
        }

        public var approximateUnixMilliseconds: Int64 {
            let elapsedMilliseconds = elapsedNanoseconds / 1_000_000
            guard elapsedMilliseconds <= UInt64(Int64.max) else { return .max }
            let (result, overflow) = anchor.unixMilliseconds.addingReportingOverflow(
                Int64(elapsedMilliseconds)
            )
            return overflow ? .max : result
        }
    }

    /// Captures wall and monotonic time once, then creates ordered timestamps.
    public struct TimelineClock: Sendable {
        public let anchor: ClockAnchor
        private let monotonicOriginNanoseconds: UInt64

        public init(wallClock: Date = Date()) {
            let milliseconds = wallClock.timeIntervalSince1970 * 1_000
            if !milliseconds.isFinite {
                anchor = ClockAnchor(unixMilliseconds: 0)
            } else if milliseconds >= Double(Int64.max) {
                anchor = ClockAnchor(unixMilliseconds: .max)
            } else if milliseconds <= Double(Int64.min) {
                anchor = ClockAnchor(unixMilliseconds: .min)
            } else {
                anchor = ClockAnchor(unixMilliseconds: Int64(milliseconds.rounded()))
            }
            monotonicOriginNanoseconds = DispatchTime.now().uptimeNanoseconds
        }

        init(anchor: ClockAnchor, monotonicOriginNanoseconds: UInt64) {
            self.anchor = anchor
            self.monotonicOriginNanoseconds = monotonicOriginNanoseconds
        }

        public func timestamp() -> Timestamp {
            timestamp(monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
        }

        func timestamp(monotonicNanoseconds: UInt64) -> Timestamp {
            Timestamp(
                anchor: anchor,
                elapsedNanoseconds: monotonicNanoseconds >= monotonicOriginNanoseconds
                    ? monotonicNanoseconds - monotonicOriginNanoseconds
                    : 0
            )
        }
    }

    public enum Source: Equatable, Hashable, Sendable {
        case feedEngine
        case player
        case avFoundation
        case localProxy
        case origin
        case cache
        case scheduler
        case exporter
        case unknown(String)
    }

    public enum Lifecycle: Equatable, Hashable, Sendable {
        case sessionStarted
        case focusRequested
        case preparing
        case ready
        case playbackStarted
        case paused
        case resumed
        case seekStarted
        case seekCompleted
        case stalled
        case recovered
        case rateChanged
        case variantSwitchStarted
        case variantSwitched
        case resourceRequested
        case resourceCompleted
        case liveEdgeChanged
        case stitchedBoundary
        case handoffStarted
        case handoffCompleted
        case completed
        case failed
        case cancelled
        case backgrounded
        case summaryEmitted
        case unknown(String)
    }

    public enum Priority: String, Codable, Sendable {
        case routine
        case important
        case critical
    }

    public enum TerminalReason: Equatable, Hashable, Sendable {
        case completed
        case abandonedBeforeStart
        case cancelled
        case backgrounded
        case failed
        case interrupted
        case unknown(String)
    }

    public struct Dimensions: Equatable, Codable, Sendable {
        public static let empty = Self(values: [:])

        public let values: [String: String]

        fileprivate init(values: [String: String]) {
            self.values = values
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let values = try container.decode([String: String].self)
            guard values.count <= DimensionCatalog.maximumKeyCount,
                  values.allSatisfy({ key, value in
                      isSafeDimensionKey(key) && isSafeToken(value, maximumLength: 32)
                  })
            else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Analytics dimensions must be bounded safe tokens."
                )
            }
            self.values = values
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }
    }

    /// A caller-defined, fixed-cardinality dimension allowlist.
    ///
    /// Keys outside the catalog are rejected. Values not explicitly approved
    /// are coalesced to `other` without retaining the original value.
    public struct DimensionCatalog: Sendable {
        public static let maximumKeyCount = 8
        public static let maximumValuesPerKey = 32
        public static let coalescedValue = "other"

        private let allowedValues: [String: Set<String>]

        public init(allowedValues: [String: Set<String>]) throws {
            guard allowedValues.count <= Self.maximumKeyCount else {
                throw ContractError.tooManyDimensionKeys(limit: Self.maximumKeyCount)
            }
            var validated: [String: Set<String>] = [:]
            validated.reserveCapacity(allowedValues.count)
            for (key, values) in allowedValues {
                guard isSafeDimensionKey(key) else {
                    throw ContractError.invalidDimensionKey
                }
                guard values.count <= Self.maximumValuesPerKey else {
                    throw ContractError.tooManyAllowedValues(
                        key: key,
                        limit: Self.maximumValuesPerKey
                    )
                }
                guard values.allSatisfy({ isSafeToken($0, maximumLength: 32) }) else {
                    throw ContractError.invalidAllowedValue(key: key)
                }
                validated[key] = values
            }
            self.allowedValues = validated
        }

        public func dimensions(from candidates: [String: String]) throws -> Dimensions {
            guard candidates.count <= Self.maximumKeyCount else {
                throw ContractError.tooManyDimensionKeys(limit: Self.maximumKeyCount)
            }
            var result: [String: String] = [:]
            result.reserveCapacity(candidates.count)
            for (candidateKey, candidateValue) in candidates {
                let key = candidateKey.lowercased()
                guard isSafeDimensionKey(key) else {
                    throw ContractError.invalidDimensionKey
                }
                guard let allowed = allowedValues[key] else {
                    throw ContractError.unknownDimensionKey
                }
                let value = candidateValue.lowercased()
                result[key] = isSafeToken(value, maximumLength: 32) && allowed.contains(value)
                    ? value
                    : Self.coalescedValue
            }
            return Dimensions(values: result)
        }
    }

    public struct MeasurementName: Hashable, Codable, Sendable {
        public let encodedValue: String

        public init(_ encodedValue: String) throws {
            guard isSafeToken(encodedValue, maximumLength: 48) else {
                throw ContractError.invalidMeasurementName
            }
            self.encodedValue = encodedValue
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedValue = try container.decode(String.self)
            guard isSafeToken(encodedValue, maximumLength: 48) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Measurement names must be bounded safe tokens."
                )
            }
            self.encodedValue = encodedValue
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(encodedValue)
        }
    }

    public enum MeasurementUnit: Equatable, Hashable, Sendable {
        case nanoseconds
        case milliseconds
        case seconds
        case bytes
        case bitsPerSecond
        case count
        case ratio
        case scalar
        case unknown(String)
    }

    public struct Measurement: Equatable, Codable, Sendable {
        public let name: MeasurementName
        public let value: Double
        public let unit: MeasurementUnit

        public init(name: MeasurementName, value: Double, unit: MeasurementUnit) throws {
            guard value.isFinite else { throw ContractError.invalidMeasurementValue }
            self.name = name
            self.value = value
            self.unit = unit
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(MeasurementName.self, forKey: .name)
            value = try container.decode(Double.self, forKey: .value)
            unit = try container.decode(MeasurementUnit.self, forKey: .unit)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Measurement values must be finite."
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case value
            case unit
        }
    }

    public struct Event: Equatable, Codable, Sendable {
        public let schemaVersion: SchemaVersion
        public let recordID: RecordID
        public let correlation: Correlation
        public let timestamp: Timestamp
        public let source: Source
        public let lifecycle: Lifecycle
        public let priority: Priority
        public let dimensions: Dimensions
        public let measurements: [Measurement]

        public init(
            schemaVersion: SchemaVersion = .current,
            recordID: RecordID = RecordID(),
            correlation: Correlation,
            timestamp: Timestamp,
            source: Source,
            lifecycle: Lifecycle,
            priority: Priority = .routine,
            dimensions: Dimensions = .empty,
            measurements: [Measurement] = []
        ) throws {
            try validate(schemaVersion)
            self.schemaVersion = schemaVersion
            self.recordID = recordID
            self.correlation = correlation
            self.timestamp = timestamp
            self.source = source
            self.lifecycle = lifecycle
            self.priority = priority
            self.dimensions = dimensions
            self.measurements = try validatedMeasurements(measurements)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
            try validate(schemaVersion)
            self.schemaVersion = schemaVersion
            recordID = try container.decode(RecordID.self, forKey: .recordID)
            correlation = try container.decode(Correlation.self, forKey: .correlation)
            timestamp = try container.decode(Timestamp.self, forKey: .timestamp)
            source = try container.decode(Source.self, forKey: .source)
            lifecycle = try container.decode(Lifecycle.self, forKey: .lifecycle)
            priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .routine
            dimensions = try container.decodeIfPresent(Dimensions.self, forKey: .dimensions) ?? .empty
            measurements = try validatedMeasurements(
                container.decodeIfPresent([Measurement].self, forKey: .measurements) ?? []
            )
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case recordID
            case correlation
            case timestamp
            case source
            case lifecycle
            case priority
            case dimensions
            case measurements
        }
    }

    /// A bounded terminal record. HLS-26 builds its metric reconciliation on
    /// this stable envelope without introducing unbounded per-item fields.
    public struct Summary: Equatable, Codable, Sendable {
        public let schemaVersion: SchemaVersion
        public let recordID: RecordID
        public let correlation: Correlation
        public let startedAt: Timestamp
        public let endedAt: Timestamp
        public let source: Source
        public let terminalReason: TerminalReason
        public let dimensions: Dimensions
        public let measurements: [Measurement]

        public init(
            schemaVersion: SchemaVersion = .current,
            recordID: RecordID = RecordID(),
            correlation: Correlation,
            startedAt: Timestamp,
            endedAt: Timestamp,
            source: Source = .feedEngine,
            terminalReason: TerminalReason,
            dimensions: Dimensions = .empty,
            measurements: [Measurement] = []
        ) throws {
            try validate(schemaVersion)
            self.schemaVersion = schemaVersion
            self.recordID = recordID
            self.correlation = correlation
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.source = source
            self.terminalReason = terminalReason
            self.dimensions = dimensions
            self.measurements = try validatedMeasurements(measurements)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
            try validate(schemaVersion)
            self.schemaVersion = schemaVersion
            recordID = try container.decode(RecordID.self, forKey: .recordID)
            correlation = try container.decode(Correlation.self, forKey: .correlation)
            startedAt = try container.decode(Timestamp.self, forKey: .startedAt)
            endedAt = try container.decode(Timestamp.self, forKey: .endedAt)
            source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .feedEngine
            terminalReason = try container.decode(TerminalReason.self, forKey: .terminalReason)
            dimensions = try container.decodeIfPresent(Dimensions.self, forKey: .dimensions) ?? .empty
            measurements = try validatedMeasurements(
                container.decodeIfPresent([Measurement].self, forKey: .measurements) ?? []
            )
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case recordID
            case correlation
            case startedAt
            case endedAt
            case source
            case terminalReason
            case dimensions
            case measurements
        }
    }

    public enum PrivacyClassification: String, Codable, Sendable {
        case fleetSafe
        case opaqueCorrelation
        case localOnly
        case forbidden
    }

    public struct FieldPrivacy: Equatable, Codable, Sendable {
        public let field: String
        public let classification: PrivacyClassification
        public let eligibleForFleetGrouping: Bool

        public init(
            field: String,
            classification: PrivacyClassification,
            eligibleForFleetGrouping: Bool
        ) {
            self.field = field
            self.classification = classification
            self.eligibleForFleetGrouping = eligibleForFleetGrouping
        }
    }

    public static let privacyManifest: [FieldPrivacy] = [
        .init(field: "schemaVersion", classification: .fleetSafe, eligibleForFleetGrouping: true),
        .init(field: "recordID", classification: .opaqueCorrelation, eligibleForFleetGrouping: false),
        .init(field: "correlation.sessionID", classification: .opaqueCorrelation, eligibleForFleetGrouping: false),
        .init(field: "correlation.playbackID", classification: .opaqueCorrelation, eligibleForFleetGrouping: false),
        .init(field: "correlation.itemID", classification: .opaqueCorrelation, eligibleForFleetGrouping: false),
        .init(field: "timestamp", classification: .fleetSafe, eligibleForFleetGrouping: false),
        .init(field: "source", classification: .fleetSafe, eligibleForFleetGrouping: true),
        .init(field: "lifecycle", classification: .fleetSafe, eligibleForFleetGrouping: true),
        .init(field: "priority", classification: .fleetSafe, eligibleForFleetGrouping: true),
        .init(field: "dimensions", classification: .fleetSafe, eligibleForFleetGrouping: true),
        .init(field: "measurements", classification: .fleetSafe, eligibleForFleetGrouping: false),
        .init(field: "rawMediaURL", classification: .forbidden, eligibleForFleetGrouping: false),
        .init(field: "ipAddress", classification: .forbidden, eligibleForFleetGrouping: false),
        .init(field: "requestHeaders", classification: .forbidden, eligibleForFleetGrouping: false),
        .init(field: "responseHeaders", classification: .forbidden, eligibleForFleetGrouping: false),
        .init(field: "authorization", classification: .forbidden, eligibleForFleetGrouping: false),
        .init(field: "userIdentifier", classification: .forbidden, eligibleForFleetGrouping: false),
    ]

    public enum Codec {
        public static func encode(_ event: Event) throws -> Data {
            try encoder().encode(event)
        }

        public static func encode(_ summary: Summary) throws -> Data {
            try encoder().encode(summary)
        }

        public static func decodeEvent(from data: Data) throws -> Event {
            try JSONDecoder().decode(Event.self, from: data)
        }

        public static func decodeSummary(from data: Data) throws -> Summary {
            try JSONDecoder().decode(Summary.self, from: data)
        }

        private static func encoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }
    }
}

extension PlaybackAnalytics.Source: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard isSafeToken(value, maximumLength: 48) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Analytics source must be a bounded safe token."
            )
        }
        self = Self.knownValue(value) ?? .unknown(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value = encodedValue
        guard isSafeToken(value, maximumLength: 48) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsafe analytics source.")
            )
        }
        try container.encode(value)
    }

    private static func knownValue(_ value: String) -> Self? {
        switch value {
        case "feed_engine": .feedEngine
        case "player": .player
        case "av_foundation": .avFoundation
        case "local_proxy": .localProxy
        case "origin": .origin
        case "cache": .cache
        case "scheduler": .scheduler
        case "exporter": .exporter
        default: nil
        }
    }

    private var encodedValue: String {
        switch self {
        case .feedEngine: "feed_engine"
        case .player: "player"
        case .avFoundation: "av_foundation"
        case .localProxy: "local_proxy"
        case .origin: "origin"
        case .cache: "cache"
        case .scheduler: "scheduler"
        case .exporter: "exporter"
        case .unknown(let value): value
        }
    }
}

extension PlaybackAnalytics.Lifecycle: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard isSafeToken(value, maximumLength: 48) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Analytics lifecycle must be a bounded safe token."
            )
        }
        self = Self.knownValue(value) ?? .unknown(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value = encodedValue
        guard isSafeToken(value, maximumLength: 48) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsafe lifecycle value.")
            )
        }
        try container.encode(value)
    }

    private static func knownValue(_ value: String) -> Self? {
        switch value {
        case "session_started": .sessionStarted
        case "focus_requested": .focusRequested
        case "preparing": .preparing
        case "ready": .ready
        case "playback_started": .playbackStarted
        case "paused": .paused
        case "resumed": .resumed
        case "seek_started": .seekStarted
        case "seek_completed": .seekCompleted
        case "stalled": .stalled
        case "recovered": .recovered
        case "rate_changed": .rateChanged
        case "variant_switch_started": .variantSwitchStarted
        case "variant_switched": .variantSwitched
        case "resource_requested": .resourceRequested
        case "resource_completed": .resourceCompleted
        case "live_edge_changed": .liveEdgeChanged
        case "stitched_boundary": .stitchedBoundary
        case "handoff_started": .handoffStarted
        case "handoff_completed": .handoffCompleted
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        case "backgrounded": .backgrounded
        case "summary_emitted": .summaryEmitted
        default: nil
        }
    }

    private var encodedValue: String {
        switch self {
        case .sessionStarted: "session_started"
        case .focusRequested: "focus_requested"
        case .preparing: "preparing"
        case .ready: "ready"
        case .playbackStarted: "playback_started"
        case .paused: "paused"
        case .resumed: "resumed"
        case .seekStarted: "seek_started"
        case .seekCompleted: "seek_completed"
        case .stalled: "stalled"
        case .recovered: "recovered"
        case .rateChanged: "rate_changed"
        case .variantSwitchStarted: "variant_switch_started"
        case .variantSwitched: "variant_switched"
        case .resourceRequested: "resource_requested"
        case .resourceCompleted: "resource_completed"
        case .liveEdgeChanged: "live_edge_changed"
        case .stitchedBoundary: "stitched_boundary"
        case .handoffStarted: "handoff_started"
        case .handoffCompleted: "handoff_completed"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .backgrounded: "backgrounded"
        case .summaryEmitted: "summary_emitted"
        case .unknown(let value): value
        }
    }
}

extension PlaybackAnalytics.TerminalReason: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard isSafeToken(value, maximumLength: 48) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Terminal reason must be a bounded safe token."
            )
        }
        switch value {
        case "completed": self = .completed
        case "abandoned_before_start": self = .abandonedBeforeStart
        case "cancelled": self = .cancelled
        case "backgrounded": self = .backgrounded
        case "failed": self = .failed
        case "interrupted": self = .interrupted
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String = switch self {
        case .completed: "completed"
        case .abandonedBeforeStart: "abandoned_before_start"
        case .cancelled: "cancelled"
        case .backgrounded: "backgrounded"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case .unknown(let value): value
        }
        guard isSafeToken(value, maximumLength: 48) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsafe terminal reason.")
            )
        }
        try container.encode(value)
    }
}

extension PlaybackAnalytics.MeasurementUnit: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard isSafeToken(value, maximumLength: 32) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Measurement unit must be a bounded safe token."
            )
        }
        switch value {
        case "nanoseconds": self = .nanoseconds
        case "milliseconds": self = .milliseconds
        case "seconds": self = .seconds
        case "bytes": self = .bytes
        case "bits_per_second": self = .bitsPerSecond
        case "count": self = .count
        case "ratio": self = .ratio
        case "scalar": self = .scalar
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String = switch self {
        case .nanoseconds: "nanoseconds"
        case .milliseconds: "milliseconds"
        case .seconds: "seconds"
        case .bytes: "bytes"
        case .bitsPerSecond: "bits_per_second"
        case .count: "count"
        case .ratio: "ratio"
        case .scalar: "scalar"
        case .unknown(let value): value
        }
        guard isSafeToken(value, maximumLength: 32) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: encoder.codingPath, debugDescription: "Unsafe measurement unit.")
            )
        }
        try container.encode(value)
    }
}

private let forbiddenDimensionKeyComponents: Set<Substring> = [
    "authorization", "cookie", "credential", "email", "header", "host",
    "ip", "token", "uri", "url", "user",
]

private func isSafeDimensionKey(_ value: String) -> Bool {
    isSafeToken(value, maximumLength: 24)
        && forbiddenDimensionKeyComponents.isDisjoint(with: value.split(separator: "_"))
}

private func isSafeToken(_ value: String, maximumLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
    return value.utf8.allSatisfy { byte in
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
    }
}

private func validate(_ version: PlaybackAnalytics.SchemaVersion) throws {
    guard version.major == PlaybackAnalytics.SchemaVersion.supportedMajor else {
        throw PlaybackAnalytics.ContractError.unsupportedSchemaMajor(version.major)
    }
}

private func validatedMeasurements(
    _ measurements: [PlaybackAnalytics.Measurement]
) throws -> [PlaybackAnalytics.Measurement] {
    let maximumCount = 32
    guard measurements.count <= maximumCount else {
        throw PlaybackAnalytics.ContractError.tooManyMeasurements(limit: maximumCount)
    }
    let sorted = measurements.sorted { $0.name.encodedValue < $1.name.encodedValue }
    for pair in zip(sorted, sorted.dropFirst()) where pair.0.name == pair.1.name {
        throw PlaybackAnalytics.ContractError.duplicateMeasurement(pair.0.name.encodedValue)
    }
    return sorted
}
