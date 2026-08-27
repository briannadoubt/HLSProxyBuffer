import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

final class FeedCoordinatorTests: XCTestCase {
    func testFocusReversalCancelsOldGenerationWithinDeadlineAndCannotPublishIt() async throws {
        let clock = LockedFeedTestClock()
        let backend = RecordingFeedPreparationBackend(
            behavior: .suspendFirstRequest(
                cancellationAdvance: .milliseconds(75),
                clock: clock,
                ignoresCancellation: true
            )
        )
        let items = makeItems(count: 5)
        let coordinator = try FeedCoordinator(
            items: items,
            policy: singleItemPolicy(),
            backend: backend,
            clock: .init(now: { clock.now() })
        )

        _ = try await coordinator.submit(signal(generation: 1, focused: items[0].id))
        try await waitUntil { await backend.requestCount() == 1 }
        let reversed = try await coordinator.submit(signal(generation: 2, focused: items[4].id))

        XCTAssertEqual(reversed.generation, .init(rawValue: 2))
        XCTAssertEqual(reversed.cancellationRequestCount, 1)
        let settled = await coordinator.waitUntilIdle()
        XCTAssertEqual(settled.readyItemIDs, [items[4].id])
        XCTAssertEqual(settled.entries.first?.itemID, items[4].id)
        XCTAssertEqual(preparedGeneration(in: settled, itemID: items[4].id), .init(rawValue: 2))
        XCTAssertEqual(settled.cancellationAcknowledgementCount, 1)
        XCTAssertEqual(settled.maximumCancellationLatency, .milliseconds(75))
        XCTAssertEqual(settled.lateCancellationCount, 0)
        XCTAssertEqual(settled.discardedStaleResultCount, 1)
        XCTAssertLessThanOrEqual(settled.maximumObservedActivePreparations, 1)
        let requestedItemIDs = await backend.requestedItemIDs()
        XCTAssertEqual(requestedItemIDs, [items[0].id, items[4].id])
    }

    func testWarmRevisitUsesCoordinatorReuseWithoutAnotherPreparation() async throws {
        let backend = RecordingFeedPreparationBackend(behavior: .immediate)
        let items = makeItems(count: 2)
        let coordinator = try FeedCoordinator(
            items: items,
            policy: singleItemPolicy(),
            backend: backend
        )

        _ = try await coordinator.submit(signal(generation: 1, focused: items[0].id))
        _ = await coordinator.waitUntilIdle()
        _ = try await coordinator.submit(signal(generation: 2, focused: items[1].id))
        _ = await coordinator.waitUntilIdle()
        let initialRequestCount = await backend.requestCount()
        XCTAssertEqual(initialRequestCount, 2)

        _ = try await coordinator.submit(signal(generation: 3, focused: items[0].id))
        let revisited = await coordinator.waitUntilIdle()

        let revisitRequestCount = await backend.requestCount()
        XCTAssertEqual(revisitRequestCount, 2)
        XCTAssertEqual(revisited.preparationCacheReuseCount, 1)
        XCTAssertEqual(revisited.readyItemIDs, [items[0].id])
        XCTAssertEqual(preparedGeneration(in: revisited, itemID: items[0].id), .init(rawValue: 3))
    }

    func testLowPowerModeAppliesPreparationAndLeadingSegmentCaps() async throws {
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.maximumLeadingSegments = 5
        policy.concurrency.maximumConcurrentPreparations = 3
        policy.lowPower.maximumPrefetchItems = 0
        policy.lowPower.maximumLeadingSegments = 1
        policy.lowPower.maximumConcurrentPreparations = 1
        let backend = RecordingFeedPreparationBackend(behavior: .immediate)
        let items = makeItems(count: 4)
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)

        _ = try await coordinator.setLowPowerModeEnabled(true)
        _ = try await coordinator.submit(signal(generation: 1, focused: items[1].id))
        let settled = await coordinator.waitUntilIdle()

        let requests = await backend.requestsSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.item.id, items[1].id)
        XCTAssertEqual(requests.first?.maximumLeadingSegments, 1)
        XCTAssertEqual(settled.maximumObservedActivePreparations, 1)
        XCTAssertEqual(settled.entries.count, 1)
        let latestPolicy = await backend.latestPolicy()
        XCTAssertEqual(latestPolicy?.concurrency.maximumConcurrentPreparations, 1)
    }

    func testInvalidCollectionsUseTypedPlanningErrorsInsteadOfDictionaryTrap() throws {
        let item = makeItems(count: 1)[0]
        let backend = RecordingFeedPreparationBackend(behavior: .immediate)

        XCTAssertThrowsError(try FeedCoordinator(
            items: [item, item],
            policy: singleItemPolicy(),
            backend: backend
        )) { error in
            XCTAssertEqual(error as? FeedPlanningError, .duplicateItemID(item.id))
        }
    }

#if canImport(Network)
    func testProductionBackendRetriesAndReusesMemoryThenDiskWithoutOriginFetch() async throws {
        let origin = try FeedFixtureOrigin(profile: .init(
            responseDelay: .milliseconds(5),
            faults: [
                .init(
                    path: "/short-a/segment-000.m4s",
                    attempts: 1...1,
                    action: .serviceUnavailable
                ),
            ]
        ))
        try await origin.start()
        defer { origin.stop() }

        let diskDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSProxyBuffer-HLS16-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: diskDirectory)
        }
        var policy = singleItemPolicy()
        policy.eviction.usesDiskCache = true
        policy.eviction.diskDirectory = diskDirectory
        policy.budget.memoryCacheBytes = 2 * 1_024 * 1_024
        policy.budget.diskCacheBytes = 8 * 1_024 * 1_024
        policy.concurrency.maximumConcurrentFetches = 2
        policy.network = HLSOriginNetworkPolicy(
            requestTimeout: 3,
            resourceTimeout: 3,
            maximumConnectionsPerHost: 1
        )
        policy.retry.segment = .init(
            maxAttempts: 2,
            initialDelay: 0,
            multiplier: 1,
            maximumDelay: 0,
            jitterRatio: 0,
            maximumRetryAfter: 0
        )
        let item = FeedPlaybackItem(
            id: "origin-item",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "short-a"),
                kind: .videoOnDemand
            ),
            estimatedPreparationBytes: 512 * 1_024
        )
        let firstBackend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true
        )
        let request = FeedPreparationRequest(
            item: item,
            generation: .init(rawValue: 1),
            role: .focused,
            maximumLeadingSegments: 1,
            maximumConcurrentFetches: 2
        )

        let cold = try await firstBackend.prepare(request)
        XCTAssertEqual(cold.leadingSegmentCount, 1)
        XCTAssertEqual(cold.originFetchCount, 3, "manifest, initialization map, and media segment")
        XCTAssertEqual(
            origin.timelineSnapshot().filter {
                $0.path == "/short-a/segment-000.m4s" && $0.kind == .requestStarted
            }.map(\.attempt),
            [1, 2]
        )
        XCTAssertLessThanOrEqual(origin.timelineSnapshot().map(\.activeRequests).max() ?? 0, 1)

        origin.resetTimeline()
        let memoryWarm = try await firstBackend.prepare(.init(
            item: item,
            generation: .init(rawValue: 2),
            role: .focused,
            maximumLeadingSegments: 1,
            maximumConcurrentFetches: 2
        ))
        XCTAssertEqual(memoryWarm.originFetchCount, 0)
        XCTAssertEqual(memoryWarm.cacheHitCount, 3)
        XCTAssertTrue(origin.timelineSnapshot().isEmpty)

        let secondBackend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true
        )
        let diskWarm = try await secondBackend.prepare(.init(
            item: item,
            generation: .init(rawValue: 3),
            role: .focused,
            maximumLeadingSegments: 1,
            maximumConcurrentFetches: 2
        ))
        XCTAssertEqual(diskWarm.originFetchCount, 0)
        XCTAssertEqual(diskWarm.cacheHitCount, 3)
        XCTAssertTrue(origin.timelineSnapshot().isEmpty)
        let diskMetrics = await secondBackend.cacheMetrics()
        XCTAssertGreaterThan(diskMetrics.diskBytes, 0)
    }

    func testProductionBackendValidatesAndPreparesCompatibleClipTimeline() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        let backend = try HLSFeedPreparationBackend(
            policy: singleItemPolicy(),
            allowsInsecureManifests: true
        )
        let clips = [
            ProxyPlaybackClip(
                id: "short-a",
                playlistURL: origin.fixturePlaylistURL(named: "short-a"),
                mediaSignature: compatibleSignature
            ),
            ProxyPlaybackClip(
                id: "short-b",
                playlistURL: origin.fixturePlaylistURL(named: "short-b"),
                mediaSignature: compatibleSignature
            ),
        ]
        let item = FeedPlaybackItem(
            id: "stitched-feed-item",
            source: .compatibleClips(clips),
            estimatedPreparationBytes: 512 * 1_024
        )

        let prepared = try await backend.prepare(.init(
            item: item,
            generation: .init(rawValue: 9),
            role: .focused,
            maximumLeadingSegments: 4,
            maximumConcurrentFetches: 2
        ))

        XCTAssertEqual(prepared.mediaPlaylistCount, 2)
        XCTAssertEqual(prepared.manifestURLs, clips.map(\.playlistURL))
        XCTAssertEqual(prepared.leadingSegmentCount, 4)
        XCTAssertEqual(prepared.preparedResourceCount, 6, "two maps plus four timeline segments")

        let incompatible = ProxyPlaybackClip(
            id: "short-b-incompatible",
            playlistURL: origin.fixturePlaylistURL(named: "short-b"),
            mediaSignature: HLSClipMediaSignature(
                container: .fragmentedMP4,
                codecs: ["hvc1.2.4.L123.B0", "mp4a.40.2"],
                tracks: [
                    .init(kind: .video, codec: "hvc1.2.4.L123.B0"),
                    .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
                ],
                videoRange: "SDR",
                segmentsAreIndependent: true
            )
        )
        let invalidItem = FeedPlaybackItem(
            id: "invalid-stitched-feed-item",
            source: .compatibleClips([clips[0], incompatible]),
            estimatedPreparationBytes: 512 * 1_024
        )
        do {
            _ = try await backend.prepare(.init(
                item: invalidItem,
                generation: .init(rawValue: 10),
                role: .focused,
                maximumLeadingSegments: 4,
                maximumConcurrentFetches: 2
            ))
            XCTFail("Incompatible media signatures must not reach resource preparation")
        } catch {
            XCTAssertEqual(
                error as? HLSClipStitchingError,
                .incompatibleMediaSignature(clipIndex: 1)
            )
        }
    }

    func testLivePolicyPreparationPublishesValidatedDVRWindow() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        var policy = FeedPlaybackPolicy.preset(.live)
        policy.prefetch.aheadItemCount = 0
        policy.budget.maximumResidentItems = 1
        let backend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true
        )
        let liveItem = FeedPlaybackItem(
            id: "fixture-live",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "live"),
                kind: .live
            ),
            estimatedPreparationBytes: 256 * 1_024
        )

        let prepared = try await backend.prepare(.init(
            item: liveItem,
            generation: .init(rawValue: 20),
            role: .focused,
            maximumLeadingSegments: 2,
            maximumConcurrentFetches: 2
        ))
        XCTAssertEqual(prepared.leadingSegmentCount, 2)
        XCTAssertEqual(prepared.liveWindow?.mediaSequenceRange, 105...107)
        XCTAssertEqual(prepared.liveWindow?.durationSeconds, 3)

        let coordinator = try FeedCoordinator(
            items: [liveItem],
            policy: policy,
            backend: backend
        )
        _ = try await coordinator.submit(signal(
            generation: 22,
            focused: liveItem.id
        ))
        let settled = await coordinator.waitUntilIdle()
        guard case .ready(let coordinated)? = settled.entries.first?.status else {
            return XCTFail("Expected the live feed item to be ready")
        }
        XCTAssertEqual(coordinated.liveWindow?.mediaSequenceRange, 105...107)
        XCTAssertLessThanOrEqual(settled.maximumObservedActivePreparations, 1)

        let mislabeledVOD = FeedPlaybackItem(
            id: "mislabeled-vod",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "short-a"),
                kind: .live
            ),
            estimatedPreparationBytes: 256 * 1_024
        )
        do {
            _ = try await backend.prepare(.init(
                item: mislabeledVOD,
                generation: .init(rawValue: 21),
                role: .focused,
                maximumLeadingSegments: 1,
                maximumConcurrentFetches: 2
            ))
            XCTFail("A live feed source must resolve to a live playlist")
        } catch {
            XCTAssertEqual(
                error as? FeedPreparationError,
                .expectedLivePlaylist(mislabeledVOD.id)
            )
        }
    }
#endif
}

private extension FeedCoordinatorTests {
    var compatibleSignature: HLSClipMediaSignature {
        HLSClipMediaSignature(
            container: .fragmentedMP4,
            codecs: ["avc1.640028", "mp4a.40.2"],
            tracks: [
                .init(kind: .video, codec: "avc1.640028"),
                .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
            ],
            videoRange: "SDR",
            segmentsAreIndependent: true
        )
    }

    func singleItemPolicy() -> FeedPlaybackPolicy {
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.aheadItemCount = 0
        policy.prefetch.behindItemCount = 0
        policy.budget.maximumResidentItems = 1
        policy.concurrency.maximumConcurrentPreparations = 1
        policy.lowPower.maximumPrefetchItems = 0
        policy.lowPower.maximumConcurrentPreparations = 1
        return policy
    }

    func makeItems(count: Int) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "coordinator-item-\(index)"),
                source: .stream(
                    url: URL(string: "https://fixture.invalid/item-\(index).m3u8")!,
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 256 * 1_024
            )
        }
    }

    func signal(generation: UInt64, focused: FeedItemID) -> FeedViewportSignal {
        FeedViewportSignal(
            generation: .init(rawValue: generation),
            focusedItemID: focused,
            visibleItems: [.init(itemID: focused, fraction: 1, distanceInViewports: 0)],
            velocityInViewportsPerSecond: 8,
            observedAt: .milliseconds(Int64(generation) * 16)
        )
    }

    func preparedGeneration(
        in snapshot: FeedCoordinatorSnapshot,
        itemID: FeedItemID
    ) -> FeedNavigationGeneration? {
        guard let entry = snapshot.entries.first(where: { $0.itemID == itemID }),
              case .ready(let value) = entry.status
        else {
            return nil
        }
        return value.generation
    }

    func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for feed coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private final class LockedFeedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.withLock { value }
    }

    func advance(by duration: Duration) {
        lock.withLock { value += max(.zero, duration) }
    }
}

private actor RecordingFeedPreparationBackend: FeedPreparing {
    enum Behavior: Sendable {
        case immediate
        case delayed(Duration)
        case suspendFirstRequest(
            cancellationAdvance: Duration,
            clock: LockedFeedTestClock,
            ignoresCancellation: Bool
        )
    }

    private let behavior: Behavior
    private var requests: [FeedPreparationRequest] = []
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var currentPolicy: FeedPlaybackPolicy?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func update(policy: FeedPlaybackPolicy) async throws {
        currentPolicy = try policy.validated()
    }

    func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem {
        requests.append(request)
        let requestNumber = requests.count
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }

        switch behavior {
        case .immediate:
            await Task.yield()
        case .delayed(let duration):
            try await Task.sleep(for: duration)
        case .suspendFirstRequest(
            let cancellationAdvance,
            let clock,
            let ignoresCancellation
        ) where requestNumber == 1:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                clock.advance(by: cancellationAdvance)
                if !ignoresCancellation {
                    throw CancellationError()
                }
            }
        case .suspendFirstRequest:
            await Task.yield()
        }

        return FeedPreparedItem(
            itemID: request.item.id,
            generation: request.generation,
            manifestURLs: [],
            mediaPlaylistCount: 1,
            leadingSegmentCount: request.maximumLeadingSegments,
            preparedResourceCount: request.maximumLeadingSegments,
            preparedByteCount: request.maximumLeadingSegments * 1_024,
            cacheHitCount: 0,
            originFetchCount: request.maximumLeadingSegments
        )
    }

    func requestCount() -> Int {
        requests.count
    }

    func requestedItemIDs() -> [FeedItemID] {
        requests.map(\.item.id)
    }

    func requestsSnapshot() -> [FeedPreparationRequest] {
        requests
    }

    func maximumObservedActiveCount() -> Int {
        maximumActiveCount
    }

    func latestPolicy() -> FeedPlaybackPolicy? {
        currentPolicy
    }
}
