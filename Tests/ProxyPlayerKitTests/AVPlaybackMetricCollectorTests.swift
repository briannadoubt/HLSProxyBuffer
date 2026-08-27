#if canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class AVPlaybackMetricCollectorTests: XCTestCase {
    func testCollectorMapsSamplesIntoCorrelatedSanitizedEvents() async throws {
        let factory = FakeAVPlaybackMetricSourceFactory(path: .nativeAVMetrics)
        let collector = makeCollector(factory: factory)
        var iterator = collector.events.makeAsyncIterator()
        let item = AVPlayerItem(url: URL(string: "https://private.example/video.m3u8?token=secret")!)
        let player = AVPlayer(playerItem: item)

        collector.attach(to: player)
        try await waitUntil { factory.sources.count == 1 }
        factory.sources[0].emit(.init(
            lifecycle: .stalled,
            priority: .important,
            measurements: AVPlaybackMetricMapper.sample(
                from: .stall(previousRate: 1)
            ).measurements
        ))

        let nextEvent = await iterator.next()
        let event = try XCTUnwrap(nextEvent)
        XCTAssertEqual(event.correlation, Self.correlation)
        XCTAssertEqual(event.source, .avFoundation)
        XCTAssertEqual(event.lifecycle, .stalled)
        XCTAssertEqual(event.priority, .important)
        XCTAssertEqual(event.measurements.map(\.name.encodedValue), [
            "previous_playback_rate", "stall_count",
        ])
        let encoded = String(decoding: try PlaybackAnalytics.Codec.encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private.example"))
        XCTAssertFalse(encoded.contains("token"))
        XCTAssertEqual(collector.snapshot.collectionPath, .nativeAVMetrics)
        XCTAssertEqual(collector.snapshot.emittedEventCount, 1)
    }

    func testItemReplacementStopsOldSourceAndRejectsLateEvents() async throws {
        let factory = FakeAVPlaybackMetricSourceFactory(path: .nativeAVMetrics)
        let collector = makeCollector(factory: factory)
        var iterator = collector.events.makeAsyncIterator()
        let firstItem = AVPlayerItem(url: URL(string: "https://example.test/first.m3u8")!)
        let secondItem = AVPlayerItem(url: URL(string: "https://example.test/second.m3u8")!)
        let player = AVPlayer(playerItem: firstItem)

        collector.attach(to: player)
        try await waitUntil { factory.sources.count == 1 }
        let firstSource = factory.sources[0]
        firstSource.emit(.init(
            lifecycle: .ready,
            priority: .important,
            measurements: []
        ))
        let firstEvent = await iterator.next()
        XCTAssertEqual(firstEvent?.lifecycle, .ready)

        player.replaceCurrentItem(with: secondItem)
        try await waitUntil { factory.sources.count == 2 }
        XCTAssertEqual(firstSource.stopCount, 1)
        XCTAssertEqual(collector.snapshot.observedItemCount, 2)
        XCTAssertEqual(collector.snapshot.activeSourceCount, 1)

        firstSource.emitAfterStop(.init(
            lifecycle: .failed,
            priority: .critical,
            measurements: []
        ))
        factory.sources[1].emit(.init(
            lifecycle: .rateChanged,
            priority: .routine,
            measurements: []
        ))
        let replacementEvent = await iterator.next()
        XCTAssertEqual(replacementEvent?.lifecycle, .rateChanged)
        XCTAssertEqual(collector.snapshot.emittedEventCount, 2)

        player.replaceCurrentItem(with: secondItem)
        await Task.yield()
        XCTAssertEqual(factory.sources.count, 2, "one item must have exactly one source")
    }

    func testBoundedStreamReportsDroppedEventsAndKeepsNewest() async throws {
        let factory = FakeAVPlaybackMetricSourceFactory(path: .nativeAVMetrics)
        let collector = makeCollector(factory: factory, eventBufferCapacity: 1)
        let player = AVPlayer(playerItem: AVPlayerItem(
            url: URL(string: "https://example.test/item.m3u8")!
        ))
        collector.attach(to: player)
        try await waitUntil { factory.sources.count == 1 }

        for lifecycle in [
            PlaybackAnalytics.Lifecycle.ready,
            .stalled,
            .recovered,
        ] {
            factory.sources[0].emit(.init(
                lifecycle: lifecycle,
                priority: .routine,
                measurements: []
            ))
        }

        XCTAssertEqual(collector.snapshot.emittedEventCount, 3)
        XCTAssertEqual(collector.snapshot.droppedEventCount, 2)
        var iterator = collector.events.makeAsyncIterator()
        let newestEvent = await iterator.next()
        XCTAssertEqual(newestEvent?.lifecycle, .recovered)
    }

    func testStopCancelsAllResourcesFinishesStreamAndReleasesPlayer() async throws {
        let factory = FakeAVPlaybackMetricSourceFactory(path: .legacyFallback)
        let collector = makeCollector(factory: factory)
        var player: AVPlayer? = AVPlayer(playerItem: AVPlayerItem(
            url: URL(string: "https://example.test/item.m3u8")!
        ))
        let weakPlayer = WeakAVObject(player)

        collector.attach(to: try XCTUnwrap(player))
        try await waitUntil { factory.sources.count == 1 }
        XCTAssertEqual(collector.snapshot.activeTaskCount, 1)
        XCTAssertEqual(collector.snapshot.activeObserverCount, 3)

        collector.stop()
        XCTAssertEqual(factory.sources[0].stopCount, 1)
        XCTAssertEqual(collector.snapshot, .init(
            collectionPath: .none,
            observedItemCount: 1,
            emittedEventCount: 0,
            droppedEventCount: 0,
            activeSourceCount: 0,
            activeTaskCount: 0,
            activeObserverCount: 0
        ))
        var iterator = collector.events.makeAsyncIterator()
        let eventAfterStop = await iterator.next()
        XCTAssertNil(eventAfterStop)

        player = nil
        try await waitUntil { weakPlayer.value == nil }
    }

    func testMapperCoversPlaybackNetworkErrorAndTerminalSignalsWithFiniteValues() throws {
        let inputs: [AVPlaybackMetricInput] = [
            .initialLikelyToKeepUp(
                duration: 0.2,
                playlistRequestCount: 1,
                mediaSegmentRequestCount: 2,
                contentKeyRequestCount: 1
            ),
            .likelyToKeepUp(duration: 0.1),
            .stall(previousRate: 1),
            .rateChanged(rate: 1.5, previousRate: 1),
            .seekStarted(rate: 0, previousRate: 1),
            .seekCompleted(rate: 1, previousRate: 0, didSeekInBuffer: true),
            .variantSwitchStarted(averageBitrate: 1_000_000, peakBitrate: 1_500_000),
            .variantSwitched(succeeded: true, averageBitrate: 2_000_000, peakBitrate: 3_000_000),
            .resource(kind: .playlist, duration: 0.01, byteCount: 400, wasCached: false, failed: false),
            .resource(kind: .mediaSegment, duration: 0.02, byteCount: 4_000, wasCached: true, failed: false),
            .resource(kind: .contentKey, duration: 0.03, byteCount: 200, wasCached: false, failed: true),
            .error(recovered: true),
            .error(recovered: false),
            .playbackCompleted,
            .summary(.init(
                recoverableErrorCount: 1,
                stallCount: 2,
                variantSwitchCount: 3,
                playbackDuration: 12,
                mediaResourceRequestCount: 8,
                stallRecoveryDuration: 0.4,
                startupDuration: 0.25,
                averageBitrate: 2_000_000,
                peakBitrate: 3_000_000
            )),
        ]

        let samples = inputs.map { AVPlaybackMetricMapper.sample(from: $0, mediaTime: 4) }
        XCTAssertEqual(samples.count, inputs.count)
        XCTAssertTrue(samples.allSatisfy { !$0.measurements.isEmpty })
        XCTAssertTrue(samples.flatMap(\.measurements).allSatisfy(\.value.isFinite))
        XCTAssertTrue(samples.contains { $0.lifecycle == .summaryEmitted })
        XCTAssertTrue(samples.contains { sample in
            sample.measurements.contains { $0.name.encodedValue == "content_key_request_count" }
        })
        XCTAssertTrue(samples.contains { sample in
            sample.measurements.contains { $0.name.encodedValue == "cache_hit_count" }
        })

        let unsafe = AVPlaybackMetricMapper.sample(
            from: .rateChanged(rate: .nan, previousRate: .infinity),
            mediaTime: -.infinity
        )
        XCTAssertTrue(unsafe.measurements.isEmpty)
    }

    func testLegacyFallbackObservesStateNotificationsAndFullyTearsDown() async throws {
        let item = AVPlayerItem(url: URL(string: "https://example.test/item.m3u8")!)
        let player = AVPlayer(playerItem: item)
        let source = LegacyAVPlaybackMetricSource(item: item, player: player)
        let sink = AVPlaybackMetricSampleSink()

        source.start { sample in sink.samples.append(sample) }
        XCTAssertEqual(source.path, .legacyFallback)
        XCTAssertGreaterThanOrEqual(source.resources.observerCount, 8)

        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: item)
        NotificationCenter.default.post(name: .AVPlayerItemNewErrorLogEntry, object: item)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitUntil {
            let lifecycles = Set(sink.samples.map(\.lifecycle))
            return lifecycles.isSuperset(of: [.stalled, .seekCompleted, .recovered, .completed])
        }

        source.stop()
        XCTAssertEqual(source.resources, .empty)
        let countAfterStop = sink.samples.count
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: item)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(sink.samples.count, countAfterStop)
    }

    private func makeCollector(
        factory: FakeAVPlaybackMetricSourceFactory,
        eventBufferCapacity: Int = 64
    ) -> AVPlaybackMetricCollector {
        AVPlaybackMetricCollector(
            correlation: Self.correlation,
            eventBufferCapacity: eventBufferCapacity,
            clock: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                monotonicOriginNanoseconds: 0
            ),
            sourceFactory: factory
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for AV metric collector state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let correlation = PlaybackAnalytics.Correlation(
        sessionID: .init(encodedValue: "11111111-1111-1111-1111-111111111111")!,
        playbackID: .init(encodedValue: "22222222-2222-2222-2222-222222222222")!,
        itemID: .init(encodedValue: "33333333-3333-3333-3333-333333333333")!
    )
}

@MainActor
private final class FakeAVPlaybackMetricSourceFactory: AVPlaybackMetricSourceFactory {
    private let path: AVPlaybackMetricCollector.CollectionPath
    private(set) var sources: [FakeAVPlaybackMetricSource] = []

    init(path: AVPlaybackMetricCollector.CollectionPath) {
        self.path = path
    }

    func makeSource(item: AVPlayerItem, player: AVPlayer) -> any AVPlaybackMetricSource {
        let source = FakeAVPlaybackMetricSource(path: path)
        sources.append(source)
        return source
    }
}

@MainActor
private final class FakeAVPlaybackMetricSource: AVPlaybackMetricSource {
    let path: AVPlaybackMetricCollector.CollectionPath
    private(set) var resources = AVPlaybackMetricSourceResources(
        taskCount: 0,
        observerCount: 0
    )
    private(set) var stopCount = 0
    private var delivery: (@MainActor @Sendable (AVPlaybackMetricSample) -> Void)?
    private var retainedDelivery: (@MainActor @Sendable (AVPlaybackMetricSample) -> Void)?

    init(path: AVPlaybackMetricCollector.CollectionPath) {
        self.path = path
    }

    func start(deliver: @escaping @MainActor @Sendable (AVPlaybackMetricSample) -> Void) {
        delivery = deliver
        retainedDelivery = deliver
        resources = .init(taskCount: 1, observerCount: 2)
    }

    func stop() {
        stopCount += 1
        delivery = nil
        resources = .empty
    }

    func emit(_ sample: AVPlaybackMetricSample) {
        delivery?(sample)
    }

    func emitAfterStop(_ sample: AVPlaybackMetricSample) {
        retainedDelivery?(sample)
    }
}

@MainActor
private final class AVPlaybackMetricSampleSink {
    var samples: [AVPlaybackMetricSample] = []
}

private final class WeakAVObject<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
#endif
