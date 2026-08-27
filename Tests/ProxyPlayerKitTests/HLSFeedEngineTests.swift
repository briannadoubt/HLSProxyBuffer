import AVFoundation
import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedEngineTests: XCTestCase {
    func testPublicInitializerKeepsCleartextRestrictedToExplicitLoopbackFixtures() async throws {
        let remoteURL = try XCTUnwrap(URL(string: "http://media.example/playlist.m3u8"))
        let remoteItem = FeedPlaybackItem(
            id: "remote-http",
            source: .stream(url: remoteURL, kind: .videoOnDemand),
            estimatedPreparationBytes: 1_024
        )
        XCTAssertThrowsError(try HLSFeedEngine(
            items: [remoteItem],
            policy: .preset(.shortFormFeed),
            sourceTransportPolicy: .allowLoopbackHTTP
        )) { error in
            XCTAssertEqual(error as? HLSFeedEngineError, .disallowedSourceURL(remoteURL))
        }

        let deceptiveURL = try XCTUnwrap(URL(string: "http://127.example/playlist.m3u8"))
        let deceptiveItem = FeedPlaybackItem(
            id: "deceptive-loopback",
            source: .stream(url: deceptiveURL, kind: .videoOnDemand),
            estimatedPreparationBytes: 1_024
        )
        XCTAssertThrowsError(try HLSFeedEngine(
            items: [deceptiveItem],
            policy: .preset(.shortFormFeed),
            sourceTransportPolicy: .allowLoopbackHTTP
        )) { error in
            XCTAssertEqual(error as? HLSFeedEngineError, .disallowedSourceURL(deceptiveURL))
        }

        let loopbackURL = try XCTUnwrap(URL(string: "http://127.0.0.1:43210/playlist.m3u8"))
        let loopbackItem = FeedPlaybackItem(
            id: "loopback-http",
            source: .stream(url: loopbackURL, kind: .videoOnDemand),
            estimatedPreparationBytes: 1_024
        )
        XCTAssertThrowsError(try HLSFeedEngine(
            items: [loopbackItem],
            policy: .preset(.shortFormFeed)
        )) { error in
            XCTAssertEqual(error as? HLSFeedEngineError, .disallowedSourceURL(loopbackURL))
        }

        let engine = try HLSFeedEngine(
            items: [loopbackItem],
            policy: .preset(.shortFormFeed),
            sourceTransportPolicy: .allowLoopbackHTTP
        )
        do {
            _ = try await engine.replaceItems([remoteItem])
            XCTFail("Replacement items must retain the engine's transport boundary")
        } catch {
            XCTAssertEqual(error as? HLSFeedEngineError, .disallowedSourceURL(remoteURL))
        }
        await engine.stop()
    }

    func testPoolIsBoundedAndReadyDestinationHandoffUsesWarmSession() async throws {
        let items = makeItems(count: 5)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        var snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, items[0].id)
        XCTAssertLessThanOrEqual(snapshot.poolOccupancy, 2)
        XCTAssertLessThanOrEqual(snapshot.allocatedPlayerCount, 2)
        XCTAssertEqual(Set(snapshot.playbacks.map(\.itemID)).count, snapshot.playbacks.count)
        let warmID = try XCTUnwrap(snapshot.playbacks.first { $0.phase == .warm }?.itemID)
        let warmSession = try XCTUnwrap(factory.session(loadedWith: warmID))
        let loadCountBeforeHandoff = warmSession.loadCount
        XCTAssertEqual(warmSession.preparationCount, 1)
        XCTAssertEqual(warmSession.playCount, 0, "speculative playback must remain paused")

        try await engine.update(signal(generation: 2, focused: warmID))
        snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, warmID)
        XCTAssertEqual(snapshot.playback(for: warmID)?.phase, .focused)
        XCTAssertEqual(
            warmSession.loadCount,
            loadCountBeforeHandoff,
            "focus must reuse the already loaded player item"
        )
        XCTAssertEqual(warmSession.playCount, 1)
        XCTAssertEqual(
            warmSession.playBeforePreparationCount,
            0,
            "focus must not start before the media pipeline is primed"
        )
        XCTAssertLessThanOrEqual(snapshot.maximumObservedPoolOccupancy, 2)

        await engine.stop()
    }

    func testNewGenerationCancelsAndRejectsStalePlayerCompletion() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(loadDelay: .milliseconds(100))
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        await Task.yield()
        try await engine.update(signal(generation: 2, focused: items[1].id))
        let snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.generation, .init(rawValue: 2))
        XCTAssertEqual(snapshot.activeItemID, items[1].id)
        XCTAssertNil(snapshot.playback(for: items[0].id))
        XCTAssertGreaterThan(snapshot.staleCompletionCount, 0)
        XCTAssertEqual(snapshot.poolOccupancy, 1)

        await engine.stop()
        XCTAssertEqual(engine.analytics.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(engine.analytics.snapshot.staleEventCount, 0)
    }

    func testStaleViewportSignalCannotMoveTargetOrActiveFocusBackward() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 2, focused: items[1].id))
        _ = await engine.waitUntilSettled()
        let staleResult = try await engine.update(signal(generation: 1, focused: items[0].id))

        XCTAssertEqual(staleResult.generation, .init(rawValue: 2))
        XCTAssertEqual(staleResult.targetFocusedItemID, items[1].id)
        XCTAssertEqual(staleResult.activeItemID, items[1].id)

        await engine.stop()
    }

    func testFailureReleasesLeaseAndAllSessionResources() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(failingItemIDs: [items[0].id])
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        let snapshot = await engine.waitUntilSettled()
        await Task.yield()

        XCTAssertEqual(snapshot.poolOccupancy, 0)
        XCTAssertNil(snapshot.activeItemID)
        XCTAssertEqual(snapshot.failures.first?.itemID, items[0].id)
        XCTAssertTrue(factory.sessions.allSatisfy { $0.stopCount == 1 })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.activeStateObserverCount == 0 })

        await engine.stop()
    }

    func testPreparationFailureNeverPublishesAnUnprimedWarmLease() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(failsPreparation: true)
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        let snapshot = await engine.waitUntilSettled()
        await Task.yield()

        XCTAssertEqual(snapshot.poolOccupancy, 0)
        XCTAssertNil(snapshot.activeItemID)
        XCTAssertEqual(snapshot.failures.first?.itemID, items[0].id)
        XCTAssertEqual(factory.sessions.first?.preparationCount, 1)
        XCTAssertEqual(factory.sessions.first?.playCount, 0)

        await engine.stop()
    }

    func testRuntimePlayerFailureAlsoReleasesItsLeaseAndObservers() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        let session = try XCTUnwrap(factory.session(loadedWith: items[0].id))
        session.failCurrentPlayback(message: "decoder failed")
        for _ in 0..<20 where engine.snapshot.poolOccupancy != 0 {
            await Task.yield()
        }

        XCTAssertEqual(engine.snapshot.poolOccupancy, 0)
        XCTAssertEqual(engine.snapshot.failures.first?.message, "decoder failed")
        XCTAssertEqual(session.stopCount, 1)
        await Task.yield()
        XCTAssertEqual(session.activeStateObserverCount, 0)

        await engine.stop()
    }

    func testLowPowerPolicyTrimsAllocatedAndOccupiedPoolBeforeReturning() async throws {
        let items = makeItems(count: 3)
        var policy = try makePolicy(maximumPlayerCount: 2)
        policy.lowPower.maximumPlayerCount = 1
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        let snapshot = try await engine.setLowPowerModeEnabled(true)

        XCTAssertLessThanOrEqual(snapshot.poolOccupancy, 1)
        XCTAssertLessThanOrEqual(snapshot.allocatedPlayerCount, 1)
        XCTAssertEqual(snapshot.activeItemID, items[0].id)

        await engine.stop()
    }

    func testCompatibleClipsLiveSourcesAndLoopingFlowThroughOneEngine() async throws {
        let signature = HLSClipMediaSignature(
            container: .fragmentedMP4,
            codecs: ["avc1.640028", "mp4a.40.2"],
            tracks: [
                .init(kind: .video, codec: "avc1.640028"),
                .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
            ],
            videoRange: "SDR",
            segmentsAreIndependent: true
        )
        let clips = [
            ProxyPlaybackClip(
                id: "clip-a",
                playlistURL: URL(string: "https://media.example/clip-a.m3u8")!,
                mediaSignature: signature
            ),
            ProxyPlaybackClip(
                id: "clip-b",
                playlistURL: URL(string: "https://media.example/clip-b.m3u8")!,
                mediaSignature: signature
            ),
        ]
        let items = [
            FeedPlaybackItem(
                id: "stitched",
                source: .compatibleClips(clips),
                estimatedPreparationBytes: 1_024
            ),
            FeedPlaybackItem(
                id: "live",
                source: .stream(
                    url: URL(string: "https://media.example/live.m3u8")!,
                    kind: .live
                ),
                estimatedPreparationBytes: 1_024
            ),
        ]
        var policy = try makePolicy(maximumPlayerCount: 2)
        policy.looping = .focusedItem
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        let stitchedSession = try XCTUnwrap(factory.session(loadedWith: items[0].id))
        XCTAssertEqual(stitchedSession.loadedClipCount, 2)
        await engine.notifyPlaybackEnded(for: items[0].id)
        XCTAssertEqual(stitchedSession.restartCount, 1)

        try await engine.updatePolicy(try policy.applying(.init(looping: .orderedCollection)))
        await engine.notifyPlaybackEnded(for: items[0].id)
        XCTAssertEqual(engine.snapshot.requestedDestinationItemID, items[1].id)

        try await engine.update(signal(generation: 2, focused: items[1].id))
        let liveSnapshot = await engine.waitUntilSettled()
        XCTAssertEqual(liveSnapshot.activeItemID, items[1].id)
        XCTAssertEqual(factory.session(loadedWith: items[1].id)?.loadedStreamKind, .live)

        await engine.stop()
    }

    func testTelemetryCapturesColdAndWarmFirstFrameHandoffsAndResources() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let telemetry = HLSFeedTelemetry()
        let engine = try makeEngine(
            items: items,
            policy: policy,
            factory: factory,
            telemetry: telemetry
        )

        try await engine.update(signal(generation: 1, focused: items[0].id))
        var engineSnapshot = await engine.waitUntilSettled()
        let warmID = try XCTUnwrap(engineSnapshot.playbacks.first { $0.phase == .warm }?.itemID)
        try await engine.update(signal(generation: 2, focused: warmID))
        engineSnapshot = await engine.waitUntilSettled()

        let coldFocusedVOD = HLSFeedTelemetry.Path(
            reuse: .cold,
            intent: .focused,
            mediaKind: .videoOnDemand
        )
        let warmFocusedVOD = HLSFeedTelemetry.Path(
            reuse: .warm,
            intent: .focused,
            mediaKind: .videoOnDemand
        )
        XCTAssertEqual(engineSnapshot.activeItemID, warmID)
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: coldFocusedVOD)?.firstFrameLatency.count,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: coldFocusedVOD)?.handoffSuccessCount,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: warmFocusedVOD)?.firstFrameLatency.count,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: warmFocusedVOD)?.handoffReadyCount,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot.resources.playerPoolOccupancy,
            engineSnapshot.poolOccupancy
        )
        XCTAssertEqual(
            telemetry.snapshot.resources.proxyPoolOccupancy,
            engineSnapshot.allocatedPlayerCount
        )

        await engine.stop()
        XCTAssertEqual(telemetry.snapshot.resources.playerPoolOccupancy, 0)
        XCTAssertEqual(telemetry.snapshot.resources.proxyPoolOccupancy, 0)
        XCTAssertGreaterThanOrEqual(telemetry.snapshot.resources.maximumPlayerPoolOccupancy, 2)
    }

    func testFirstFrameAndHandoffWaitForPlatformPlaybackToActuallyStart() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(usesUnstartedPlatformPlayer: true)
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        let settled = await engine.waitUntilSettled()

        XCTAssertEqual(settled.activeItemID, items[0].id)
        XCTAssertEqual(settled.playback(for: items[0].id)?.hasStartedPlayback, false)
        XCTAssertEqual(engine.telemetry.snapshot.firstFrameCount, 0)
        XCTAssertEqual(engine.telemetry.snapshot.handoffSuccessCount, 0)

        await engine.stop()
        let handoffAttempts = engine.telemetry.snapshot.paths.reduce(UInt64(0)) {
            $0 + $1.handoffAttemptCount
        }
        XCTAssertEqual(handoffAttempts, 1)
        XCTAssertEqual(engine.telemetry.snapshot.handoffSuccessCount, 0)
    }

    func testTelemetryCapturesFocusedPlaybackStallsAndCancellationOutcomes() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(loadDelay: .milliseconds(100))
        let telemetry = HLSFeedTelemetry()
        let engine = try makeEngine(
            items: items,
            policy: policy,
            factory: factory,
            telemetry: telemetry
        )

        try await engine.update(signal(generation: 1, focused: items[0].id))
        for _ in 0..<100 where engine.snapshot.activeLoadCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(engine.snapshot.activeLoadCount, 1)
        try await engine.update(signal(generation: 2, focused: items[1].id))
        _ = await engine.waitUntilSettled()
        let session = try XCTUnwrap(factory.session(loadedWith: items[1].id))
        XCTAssertEqual(engine.snapshot.playback(for: items[1].id)?.phase, .focused)
        XCTAssertEqual(engine.snapshot.playback(for: items[1].id)?.state.status, .ready)
        for _ in 0..<100 where session.activeStateObserverCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(
            session.activeStateObserverCount,
            1,
            "load=\(session.loadCount) stop=\(session.stopCount) sessions=\(factory.sessions.count)"
        )
        session.beginBuffering()
        for _ in 0..<20 where engine.snapshot.playback(for: items[1].id)?.state.status != .buffering {
            await Task.yield()
        }
        XCTAssertEqual(engine.snapshot.playback(for: items[1].id)?.state.status, .buffering)
        session.recoverPlayback()
        for _ in 0..<20 where telemetry.snapshot.stallCount == 0 {
            await Task.yield()
        }

        XCTAssertGreaterThanOrEqual(
            telemetry.snapshot.cancellationCount,
            1,
            String(describing: telemetry.snapshot)
        )
        XCTAssertEqual(telemetry.snapshot.stallCount, 1)

        session.beginBuffering()
        for _ in 0..<20 where engine.snapshot.playback(for: items[1].id)?.state.status != .buffering {
            await Task.yield()
        }
        await engine.stop()
        XCTAssertEqual(telemetry.snapshot.stallCount, 2, "stop must close an in-flight stall")
    }

    func testAnalyticsAutomaticallyPreservesCorrelationAcrossPredictionAndWarmHandoff() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let analytics = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 128,
            maximumActiveAttemptCount: 4
        ))
        let engine = try makeEngine(
            items: items,
            policy: policy,
            factory: factory,
            analytics: analytics
        )
        let eventTask = Task { @MainActor in
            var events: [PlaybackAnalytics.Event] = []
            for await event in analytics.events { events.append(event) }
            return events
        }

        try await engine.update(signal(generation: 1, focused: items[0].id))
        var settled = await engine.waitUntilSettled()
        let warmID = try XCTUnwrap(settled.playbacks.first { $0.phase == .warm }?.itemID)
        let warmSession = try XCTUnwrap(factory.session(loadedWith: warmID))
        warmSession.publishStreaming(streamingSnapshot(originBytes: 2_048))
        await Task.yield()

        try await engine.update(signal(generation: 2, focused: warmID))
        settled = await engine.waitUntilSettled()
        XCTAssertEqual(settled.activeItemID, warmID)
        warmSession.publishStreaming(streamingSnapshot(originBytes: 4_096))
        await Task.yield()
        await engine.stop()

        let events = await eventTask.value
        let warmOriginEvent = try XCTUnwrap(events.first { event in
            event.measurements.contains {
                $0.name.encodedValue == "origin_bytes" && $0.value == 2_048
            }
        })
        let correlated = events.filter { $0.correlation == warmOriginEvent.correlation }
        XCTAssertTrue(correlated.contains {
            $0.dimensions.values["feed_intent"] == "predicted"
        })
        XCTAssertTrue(correlated.contains {
            $0.dimensions.values["feed_intent"] == "focused"
                && $0.dimensions.values["cache_reuse"] == "warm"
        })
        XCTAssertTrue(correlated.contains { $0.lifecycle == .handoffCompleted })
        XCTAssertTrue(correlated.contains {
            $0.source == .origin
                && $0.dimensions.values["network_leg"] == "proxy_origin"
        })
        XCTAssertTrue(correlated.contains { event in
            event.measurements.contains {
                $0.name.encodedValue == "origin_bytes" && $0.value == 2_048
            }
        })
        let sequences = events.compactMap { event in
            event.measurements.first { $0.name.encodedValue == "timeline_sequence" }?.value
        }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
        XCTAssertEqual(analytics.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(analytics.snapshot.staleEventCount, 0)
    }

    func testFiveHundredTransitionsLeaveNoTasksObserversOrListeners() async throws {
        struct EnduranceReport: Codable {
            let transitionCount: Int
            let maximumPlayerPoolOccupancy: Int
            let maximumAllocatedPlayerCount: Int
            let maximumPlayerPoolLimit: Int
            let allocatedSessionCount: Int
            let finalPoolOccupancy: Int
            let finalAllocatedPlayerCount: Int
            let finalActiveLoadCount: Int
            let activeObserverCount: Int
            let stoppedSessionCount: Int
            let handoffAttemptCount: UInt64
            let handoffSuccessCount: UInt64
            let handoffSuccessRate: Double
        }
        let items = makeItems(count: 11)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)
        var maximumAllocatedPlayerCount = 0

        for step in 0..<500 {
            let focused = items[step % items.count].id
            try await engine.update(signal(
                generation: UInt64(step + 1),
                focused: focused,
                velocity: step.isMultiple(of: 2) ? 8 : -8
            ))
            let snapshot = await engine.waitUntilSettled()
            XCTAssertLessThanOrEqual(snapshot.poolOccupancy, 2)
            XCTAssertLessThanOrEqual(snapshot.allocatedPlayerCount, 2)
            maximumAllocatedPlayerCount = max(
                maximumAllocatedPlayerCount,
                snapshot.allocatedPlayerCount
            )
            XCTAssertEqual(Set(snapshot.playbacks.map(\.itemID)).count, snapshot.playbacks.count)
        }

        await engine.stop()
        await Task.yield()
        XCTAssertEqual(engine.snapshot.poolOccupancy, 0)
        XCTAssertEqual(engine.snapshot.allocatedPlayerCount, 0)
        XCTAssertEqual(engine.snapshot.activeLoadCount, 0)
        XCTAssertLessThanOrEqual(factory.sessions.count, 2)
        XCTAssertTrue(factory.sessions.allSatisfy { $0.activeStateObserverCount == 0 })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.isStopped })
        let summary = try engine.telemetry.machineReadableSummary()
        let decoded = try JSONDecoder().decode(HLSFeedTelemetry.Snapshot.self, from: summary)
        XCTAssertEqual(decoded, engine.telemetry.snapshot)
        XCTAssertGreaterThanOrEqual(decoded.handoffSuccessCount, 500)
        let handoffAttemptCount = decoded.paths.reduce(UInt64(0)) {
            $0 &+ $1.handoffAttemptCount
        }
        let handoffSuccessRate = Double(decoded.handoffSuccessCount) / Double(handoffAttemptCount)
        XCTAssertGreaterThanOrEqual(handoffSuccessRate, 0.99)
        try QualificationArtifact.write(
            EnduranceReport(
                transitionCount: 500,
                maximumPlayerPoolOccupancy: decoded.resources.maximumPlayerPoolOccupancy,
                maximumAllocatedPlayerCount: maximumAllocatedPlayerCount,
                maximumPlayerPoolLimit: policy.concurrency.maximumPlayerCount,
                allocatedSessionCount: factory.sessions.count,
                finalPoolOccupancy: engine.snapshot.poolOccupancy,
                finalAllocatedPlayerCount: engine.snapshot.allocatedPlayerCount,
                finalActiveLoadCount: engine.snapshot.activeLoadCount,
                activeObserverCount: factory.sessions.reduce(0) { $0 + $1.activeStateObserverCount },
                stoppedSessionCount: factory.sessions.filter(\.isStopped).count,
                handoffAttemptCount: handoffAttemptCount,
                handoffSuccessCount: decoded.handoffSuccessCount,
                handoffSuccessRate: handoffSuccessRate
            ),
            named: "hls-feed-engine-endurance.json"
        )
    }

    private func makeEngine(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        factory: FakeFeedSessionFactory,
        telemetry: HLSFeedTelemetry? = nil,
        analytics: PlaybackAnalyticsTimeline? = nil
    ) throws -> HLSFeedEngine {
        let backend = ImmediateFeedPreparationBackend()
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)
        return try HLSFeedEngine(
            items: items,
            policy: policy,
            coordinator: coordinator,
            sessionFactory: { configuration in factory.make(configuration: configuration) },
            telemetry: telemetry ?? HLSFeedTelemetry(),
            analytics: analytics ?? PlaybackAnalyticsTimeline()
        )
    }

    private func streamingSnapshot(originBytes: Int) -> HLSStreamingTelemetry.Snapshot {
        .init(
            segmentFetchLatency: .init(
                upperBounds: [1],
                bucketCounts: [1, 0],
                count: 1,
                sum: 0.1,
                minimum: 0.1,
                maximum: 0.1
            ),
            fetchErrorCounts: [:],
            retryOutcomeCounts: [.successWithoutRetry: 1],
            cacheHitCount: 1,
            cacheMissCount: 1,
            liveEdgeDistanceSeconds: nil,
            variantSwitchReasonCounts: [:],
            latestVariantSwitchReason: nil,
            originByteCount: originBytes,
            schedulerScheduledCount: 2,
            schedulerReadyCount: 2
        )
    }

    private func makeItems(count: Int) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: FeedItemID(rawValue: "item-\(index)"),
                source: .stream(
                    url: URL(string: "https://media.example/item-\(index).m3u8")!,
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 1_024
            )
        }
    }

    private func makePolicy(
        maximumPlayerCount: Int,
        prefetchItemCount: Int = 1
    ) throws -> FeedPlaybackPolicy {
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.aheadItemCount = prefetchItemCount
        policy.prefetch.behindItemCount = 0
        policy.budget.maximumResidentItems = 1 + prefetchItemCount
        policy.concurrency.maximumPlayerCount = maximumPlayerCount
        policy.eviction.offscreenGracePeriod = 0
        policy.lowPower.maximumPrefetchItems = min(
            policy.lowPower.maximumPrefetchItems,
            prefetchItemCount
        )
        policy.lowPower.maximumPlayerCount = min(
            policy.lowPower.maximumPlayerCount,
            maximumPlayerCount
        )
        return try policy.validated()
    }

    private func signal(
        generation: UInt64,
        focused: FeedItemID,
        velocity: Double = 0
    ) -> FeedViewportSignal {
        FeedViewportSignal(
            generation: .init(rawValue: generation),
            focusedItemID: focused,
            visibleItems: [.init(
                itemID: focused,
                fraction: 1,
                distanceInViewports: 0
            )],
            velocityInViewportsPerSecond: velocity,
            observedAt: .milliseconds(Int64(generation))
        )
    }
}

private actor ImmediateFeedPreparationBackend: FeedPreparing {
    func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem {
        try Task.checkCancellation()
        return FeedPreparedItem(
            itemID: request.item.id,
            generation: request.generation,
            manifestURLs: request.item.source.urlsForTestPreparation,
            mediaPlaylistCount: 1,
            leadingSegmentCount: request.maximumLeadingSegments,
            preparedResourceCount: request.maximumLeadingSegments,
            preparedByteCount: request.item.estimatedPreparationBytes,
            cacheHitCount: 0,
            originFetchCount: 1
        )
    }
}

private extension FeedPlaybackSource {
    var urlsForTestPreparation: [URL] {
        switch self {
        case .stream(let url, _): [url]
        case .clips(let urls): urls
        case .compatibleClips(let clips): clips.map(\.playlistURL)
        }
    }
}

@MainActor
private final class FakeFeedSessionFactory {
    let loadDelay: Duration
    let failingItemIDs: Set<FeedItemID>
    let failsPreparation: Bool
    let usesUnstartedPlatformPlayer: Bool
    private(set) var sessions: [FakeFeedPlayerSession] = []

    init(
        loadDelay: Duration = .zero,
        failingItemIDs: Set<FeedItemID> = [],
        failsPreparation: Bool = false,
        usesUnstartedPlatformPlayer: Bool = false
    ) {
        self.loadDelay = loadDelay
        self.failingItemIDs = failingItemIDs
        self.failsPreparation = failsPreparation
        self.usesUnstartedPlatformPlayer = usesUnstartedPlatformPlayer
    }

    func make(configuration: ProxyPlayerConfiguration) -> FakeFeedPlayerSession {
        let session = FakeFeedPlayerSession(
            configuration: configuration,
            loadDelay: loadDelay,
            failingItemIDs: failingItemIDs,
            failsPreparation: failsPreparation,
            platformPlayer: usesUnstartedPlatformPlayer ? AVPlayer() : nil
        )
        sessions.append(session)
        return session
    }

    func session(loadedWith itemID: FeedItemID) -> FakeFeedPlayerSession? {
        sessions.first { $0.loadedItemID == itemID }
    }
}

@MainActor
private final class FakeFeedPlayerSession: HLSFeedPlayerSession {
    private(set) var state = PlayerState()
    let feedPlatformPlayer: AVPlayer?
    private(set) var configuration: ProxyPlayerConfiguration
    private(set) var loadedItemID: FeedItemID?
    private(set) var loadedStreamKind: FeedStreamKind?
    private(set) var loadedClipCount = 0
    private(set) var loadCount = 0
    private(set) var preparationCount = 0
    private(set) var playCount = 0
    private(set) var playBeforePreparationCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var restartCount = 0
    private(set) var isStopped = false
    private(set) var activeStateObserverCount = 0

    private let loadDelay: Duration
    private let failingItemIDs: Set<FeedItemID>
    private let failsPreparation: Bool
    private var continuations: [UUID: AsyncStream<PlayerState>.Continuation] = [:]
    private var streamingContinuations: [
        UUID: AsyncStream<HLSStreamingTelemetry.Snapshot>.Continuation
    ] = [:]
    private var streamingSnapshot = HLSStreamingTelemetry.Snapshot.empty

    init(
        configuration: ProxyPlayerConfiguration,
        loadDelay: Duration,
        failingItemIDs: Set<FeedItemID>,
        failsPreparation: Bool,
        platformPlayer: AVPlayer?
    ) {
        self.configuration = configuration
        self.loadDelay = loadDelay
        self.failingItemIDs = failingItemIDs
        self.failsPreparation = failsPreparation
        self.feedPlatformPlayer = platformPlayer
    }

    func stateUpdates() -> AsyncStream<PlayerState> {
        let id = UUID()
        activeStateObserverCount += 1
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.continuations.removeValue(forKey: id) != nil else { return }
                    self.activeStateObserverCount -= 1
                }
            }
        }
    }

    func telemetryUpdates() async -> AsyncStream<HLSStreamingTelemetry.Snapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            streamingContinuations[id] = continuation
            continuation.yield(streamingSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streamingContinuations.removeValue(forKey: id) }
            }
        }
    }

    func load(
        from remoteURL: URL,
        quality: HLSRewriteConfiguration.QualityPolicy
    ) async {
        loadCount += 1
        loadedClipCount = 0
        loadedStreamKind = remoteURL.lastPathComponent == "live.m3u8" ? .live : .videoOnDemand
        loadedItemID = Self.itemID(from: remoteURL)
        transition(to: PlayerState(status: .buffering))
        if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
        if let loadedItemID, failingItemIDs.contains(loadedItemID) {
            transition(to: PlayerState(status: .failed("fixture failure")))
        } else {
            transition(to: PlayerState(status: .ready, bufferDepthSeconds: 2))
        }
        isStopped = false
    }

    func load(clips: [ProxyPlaybackClip]) async throws {
        loadCount += 1
        loadedClipCount = clips.count
        loadedStreamKind = nil
        loadedItemID = FeedItemID(rawValue: "stitched")
        transition(to: PlayerState(status: .ready, bufferDepthSeconds: 2))
        isStopped = false
    }

    func prepareForImmediatePlayback() async -> Bool {
        preparationCount += 1
        return !failsPreparation
    }

    func play() {
        playCount += 1
        if preparationCount == 0 { playBeforePreparationCount += 1 }
    }
    func pause() { pauseCount += 1 }
    func setPlaybackRate(_ rate: Float) {}
    func jumpToLive() async throws {}
    func seek(secondsBehindLiveEdge: TimeInterval) async throws {}

    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        self.configuration = configuration
    }

    func stopAndWait() async {
        stopCount += 1
        isStopped = true
        transition(to: PlayerState())
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        for continuation in streamingContinuations.values { continuation.finish() }
        streamingContinuations.removeAll()
        activeStateObserverCount = 0
    }

    func restartPlayback() async {
        restartCount += 1
        play()
    }

    func failCurrentPlayback(message: String) {
        transition(to: PlayerState(status: .failed(message)))
    }

    func beginBuffering() {
        transition(to: PlayerState(status: .buffering))
    }

    func recoverPlayback() {
        transition(to: PlayerState(status: .ready, bufferDepthSeconds: 2))
    }

    func publishStreaming(_ snapshot: HLSStreamingTelemetry.Snapshot) {
        streamingSnapshot = snapshot
        for continuation in streamingContinuations.values { continuation.yield(snapshot) }
    }

    private func transition(to state: PlayerState) {
        self.state = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    private static func itemID(from url: URL) -> FeedItemID {
        let name = url.deletingPathExtension().lastPathComponent
        return FeedItemID(rawValue: name)
    }
}
