import Foundation
import XCTest
@testable import ProxyPlayerKit

final class PlaybackAnalyticsContractTests: XCTestCase {
    func testOpaqueIdentifiersRoundTripWithoutAcceptingApplicationText() throws {
        let session = PlaybackAnalytics.SessionID()
        let playback = PlaybackAnalytics.PlaybackID()
        let item = PlaybackAnalytics.ItemID()
        let record = PlaybackAnalytics.RecordID()

        XCTAssertNotEqual(session.encodedValue, playback.encodedValue)
        XCTAssertNotEqual(playback.encodedValue, item.encodedValue)
        XCTAssertNotEqual(item.encodedValue, record.encodedValue)
        XCTAssertEqual(
            PlaybackAnalytics.SessionID(encodedValue: session.encodedValue),
            session
        )
        XCTAssertNil(PlaybackAnalytics.ItemID(encodedValue: "application-item-123"))
        XCTAssertFalse(session.encodedValue.contains("application"))
    }

    func testTimelineUsesMonotonicElapsedTimeFromOneWallClockAnchor() {
        let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 1_700_000_000_000)
        let clock = PlaybackAnalytics.TimelineClock(
            anchor: anchor,
            monotonicOriginNanoseconds: 2_000
        )

        let first = clock.timestamp(monotonicNanoseconds: 2_500)
        let second = clock.timestamp(monotonicNanoseconds: 7_500)

        XCTAssertEqual(first.anchor, anchor)
        XCTAssertEqual(first.elapsedNanoseconds, 500)
        XCTAssertEqual(second.elapsedNanoseconds, 5_500)
        XCTAssertGreaterThan(second.elapsedNanoseconds, first.elapsedNanoseconds)
        XCTAssertEqual(second.approximateUnixMilliseconds, 1_700_000_000_000)
    }

    func testDimensionCatalogPreservesOnlyApprovedBoundedValues() throws {
        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "media_kind": ["vod", "live", "stitched"],
            "cohort": ["control", "candidate"],
        ])

        let approved = try catalog.dimensions(from: [
            "cache_reuse": "WARM",
            "media_kind": "vod",
        ])
        XCTAssertEqual(approved.values, ["cache_reuse": "warm", "media_kind": "vod"])

        for sensitiveCandidate in [
            "https://media.example/private.m3u8?token=secret",
            "192.0.2.42",
            "viewer@example.com",
            "0f98dc4d-0fd8-41ef-af7f-ad05a5c4c2dc",
            "unbounded-campaign-928471",
        ] {
            let dimensions = try catalog.dimensions(from: ["cohort": sensitiveCandidate])
            XCTAssertEqual(dimensions.values, ["cohort": "other"])
            XCTAssertFalse(dimensions.values.values.contains(sensitiveCandidate))
        }
    }

    func testInvalidAndHighCardinalityDimensionDefinitionsAreRejected() throws {
        XCTAssertThrowsError(try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "user_id": ["someone"],
        ])) { error in
            XCTAssertEqual(error as? PlaybackAnalytics.ContractError, .invalidDimensionKey)
        }

        let tooManyKeys = Dictionary(uniqueKeysWithValues: (0..<9).map {
            ("dimension_\($0)", Set(["value"]))
        })
        XCTAssertThrowsError(try PlaybackAnalytics.DimensionCatalog(allowedValues: tooManyKeys)) {
            error in
            XCTAssertEqual(
                error as? PlaybackAnalytics.ContractError,
                .tooManyDimensionKeys(limit: 8)
            )
        }

        let tooManyValues = Set((0..<33).map { "value_\($0)" })
        XCTAssertThrowsError(try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "experiment": tooManyValues,
        ]))

        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "media_kind": ["vod"],
        ])
        XCTAssertThrowsError(try catalog.dimensions(from: ["unknown_key": "vod"])) {
            error in
            XCTAssertEqual(
                error as? PlaybackAnalytics.ContractError,
                .unknownDimensionKey
            )
        }
    }

    func testMeasurementsAreFiniteUniqueAndDeterministicallyOrdered() throws {
        let zeta = try PlaybackAnalytics.Measurement(
            name: .init("zeta_count"),
            value: 2,
            unit: .count
        )
        let alpha = try PlaybackAnalytics.Measurement(
            name: .init("alpha_seconds"),
            value: 1.5,
            unit: .seconds
        )
        let event = try makeEvent(measurements: [zeta, alpha])

        XCTAssertEqual(
            event.measurements.map(\.name.encodedValue),
            ["alpha_seconds", "zeta_count"]
        )
        XCTAssertThrowsError(try makeEvent(measurements: [alpha, alpha]))
        XCTAssertThrowsError(try PlaybackAnalytics.Measurement(
            name: .init("invalid"),
            value: .infinity,
            unit: .scalar
        ))
    }

    func testCurrentEventEncodingMatchesGoldenFixtureExactly() throws {
        let data = try PlaybackAnalytics.Codec.encode(makeEvent())
        XCTAssertEqual(data, try goldenData(named: "analytics-event-v1"))
        XCTAssertEqual(try PlaybackAnalytics.Codec.decodeEvent(from: data), try makeEvent())
    }

    func testCurrentSummaryEncodingMatchesGoldenFixtureExactly() throws {
        let data = try PlaybackAnalytics.Codec.encode(makeSummary())
        XCTAssertEqual(data, try goldenData(named: "analytics-summary-v1"))
        XCTAssertEqual(try PlaybackAnalytics.Codec.decodeSummary(from: data), try makeSummary())
    }

    func testDecoderAcceptsBackwardMinimalAndForwardMinorFixtures() throws {
        let backward = try PlaybackAnalytics.Codec.decodeEvent(
            from: fixtureData(named: "analytics-event-v1-minimal")
        )
        XCTAssertEqual(backward.priority, .routine)
        XCTAssertEqual(backward.dimensions, .empty)
        XCTAssertTrue(backward.measurements.isEmpty)

        let forward = try PlaybackAnalytics.Codec.decodeEvent(
            from: fixtureData(named: "analytics-event-v1-forward-minor")
        )
        XCTAssertEqual(forward.schemaVersion, .init(major: 1, minor: 99))
        XCTAssertEqual(forward.source, .unknown("future_collector"))
        XCTAssertEqual(forward.lifecycle, .unknown("decoder_primed"))
        let reencoded = String(
            decoding: try PlaybackAnalytics.Codec.encode(forward),
            as: UTF8.self
        )
        XCTAssertTrue(reencoded.contains("future_collector"))
        XCTAssertTrue(reencoded.contains("decoder_primed"))
        XCTAssertThrowsError(try PlaybackAnalytics.Codec.encode(try makeEvent(
            source: .unknown("https://unsafe.example")
        )))
    }

    func testDecoderRejectsFutureMajorFixture() throws {
        XCTAssertThrowsError(try PlaybackAnalytics.Codec.decodeEvent(
            from: fixtureData(named: "analytics-event-v2-incompatible")
        )) { error in
            XCTAssertEqual(
                error as? PlaybackAnalytics.ContractError,
                .unsupportedSchemaMajor(2)
            )
        }
    }

    func testPrivacyManifestAndEncodedRecordsExcludeSensitiveRequestData() throws {
        let forbidden = Set(PlaybackAnalytics.privacyManifest.compactMap { entry in
            entry.classification == .forbidden ? entry.field : nil
        })
        XCTAssertEqual(forbidden, [
            "authorization", "ipAddress", "rawMediaURL", "requestHeaders",
            "responseHeaders", "userIdentifier",
        ])
        XCTAssertTrue(
            PlaybackAnalytics.privacyManifest
                .filter { $0.classification == .opaqueCorrelation }
                .allSatisfy { !$0.eligibleForFleetGrouping }
        )

        let encoded = String(
            decoding: try PlaybackAnalytics.Codec.encode(makeEvent()),
            as: UTF8.self
        )
        for forbiddenText in [
            "https://", "192.0.2.42", "authorization", "request_headers",
            "response_headers", "user_identifier", "example.com",
        ] {
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(forbiddenText))
        }
    }

    func testPublicRecordsAreCodableAndSendable() {
        assertCodableAndSendable(PlaybackAnalytics.Event.self)
        assertCodableAndSendable(PlaybackAnalytics.Summary.self)
        assertCodableAndSendable(PlaybackAnalytics.Correlation.self)
        assertCodableAndSendable(PlaybackAnalytics.Timestamp.self)
    }

    private func makeEvent(
        source: PlaybackAnalytics.Source = .feedEngine,
        measurements: [PlaybackAnalytics.Measurement]? = nil
    ) throws -> PlaybackAnalytics.Event {
        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "media_kind": ["vod", "live", "stitched"],
        ])
        return try PlaybackAnalytics.Event(
            recordID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000004"
            )),
            correlation: try correlation(),
            timestamp: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 250_000_000
            ),
            source: source,
            lifecycle: .playbackStarted,
            priority: .important,
            dimensions: try catalog.dimensions(from: [
                "cache_reuse": "warm",
                "media_kind": "vod",
            ]),
            measurements: try measurements ?? [
                .init(
                    name: .init("first_frame_latency"),
                    value: 187.5,
                    unit: .milliseconds
                ),
            ]
        )
    }

    private func makeSummary() throws -> PlaybackAnalytics.Summary {
        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "media_kind": ["vod", "live", "stitched"],
        ])
        return try PlaybackAnalytics.Summary(
            recordID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000005"
            )),
            correlation: try correlation(),
            startedAt: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 0
            ),
            endedAt: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 12_500_000_000
            ),
            terminalReason: .completed,
            dimensions: try catalog.dimensions(from: [
                "cache_reuse": "warm",
                "media_kind": "vod",
            ]),
            measurements: [
                try .init(name: .init("origin_bytes"), value: 1_024, unit: .bytes),
                try .init(name: .init("watch_duration"), value: 12.5, unit: .seconds),
            ]
        )
    }

    private func correlation() throws -> PlaybackAnalytics.Correlation {
        PlaybackAnalytics.Correlation(
            sessionID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000001"
            )),
            playbackID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000002"
            )),
            itemID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000003"
            ))
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Analytics"
        ))
        return try Data(contentsOf: url)
    }

    private func goldenData(named name: String) throws -> Data {
        var data = try fixtureData(named: name)
        if data.last == 0x0A { data.removeLast() }
        return data
    }

    private func assertCodableAndSendable<T: Codable & Sendable>(_: T.Type) {}
}
