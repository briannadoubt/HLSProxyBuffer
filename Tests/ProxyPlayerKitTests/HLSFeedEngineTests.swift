import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedEngineTests: XCTestCase {
    func testMemoryPressureHookShedsSharedMemoryWithoutDiscardingDiskBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSFeedEnginePressure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HLSSegmentCache(
            capacityBytes: 1_024,
            diskDirectory: directory,
            diskCapacityBytes: 4_096
        )
        await cache.put(Data(repeating: 0xAB, count: 128), for: "segment-engine-pressure")
        let items = makeItems(count: 1)
        let engine = try makeEngine(
            items: items,
            policy: makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0),
            factory: FakeFeedSessionFactory(),
            sharedCache: cache
        )

        await engine.handleMemoryPressure()

        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.totalBytes, 0)
        XCTAssertEqual(metrics.diskBytes, 128)
        XCTAssertEqual(metrics.evictionCounts[.memoryPressure], 1)
        await engine.stop()
    }

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
        XCTAssertEqual(snapshot.audibleItemID, items[0].id)
        XCTAssertEqual(snapshot.playback(for: items[0].id)?.isAudible, true)
        XCTAssertLessThanOrEqual(snapshot.poolOccupancy, 2)
        XCTAssertLessThanOrEqual(snapshot.allocatedPlayerCount, 2)
        XCTAssertEqual(Set(snapshot.playbacks.map(\.itemID)).count, snapshot.playbacks.count)
        let warmID = try XCTUnwrap(snapshot.playbacks.first { $0.phase == .warm }?.itemID)
        let warmSession = try XCTUnwrap(factory.session(loadedWith: warmID))
        let loadCountBeforeHandoff = warmSession.loadCount
        XCTAssertEqual(warmSession.preparationCount, 1)
        XCTAssertEqual(warmSession.playCount, 0, "speculative playback must remain paused")
        XCTAssertTrue(warmSession.isMuted, "speculative playback must never own audio")

        try await engine.update(signal(generation: 2, focused: warmID))
        snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, warmID)
        XCTAssertEqual(snapshot.audibleItemID, warmID)
        XCTAssertFalse(warmSession.isMuted)
        XCTAssertEqual(factory.audiblePlayingItemIDs, [warmID])
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
        XCTAssertEqual(snapshot.maximumObservedAudiblePlaybackCount, 1)
        XCTAssertEqual(factory.maximumAudiblePlayingCount, 1)

        await engine.stop()
    }

    func testNotReadyFocusSilencesPreviousAudioUntilDestinationIsPrepared() async throws {
        let items = makeItems(count: 4)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory(loadDelay: .milliseconds(100))
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        XCTAssertEqual(factory.audiblePlayingItemIDs, [items[0].id])

        let loading = try await engine.update(signal(generation: 2, focused: items[3].id))
        XCTAssertNil(loading.activeItemID)
        XCTAssertNil(loading.audibleItemID)
        XCTAssertTrue(factory.audiblePlayingItemIDs.isEmpty)

        let settled = await engine.waitUntilSettled()
        XCTAssertEqual(settled.activeItemID, items[3].id)
        XCTAssertEqual(settled.audibleItemID, items[3].id)
        XCTAssertEqual(factory.audiblePlayingItemIDs, [items[3].id])
        XCTAssertEqual(factory.maximumAudiblePlayingCount, 1)
        XCTAssertEqual(settled.maximumObservedAudiblePlaybackCount, 1)

        await engine.stop()
    }

    func testRapidDirectionReversalCannotLetLateDestinationStealAudio() async throws {
        let items = makeItems(count: 4)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory(loadDelay: .milliseconds(100))
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        _ = try await engine.update(signal(
            generation: 2,
            focused: items[3].id,
            velocity: 12
        ))
        _ = try await engine.update(signal(
            generation: 3,
            focused: items[0].id,
            velocity: -12
        ))
        let settled = await engine.waitUntilSettled()

        XCTAssertEqual(settled.generation, .init(rawValue: 3))
        XCTAssertEqual(settled.activeItemID, items[0].id)
        XCTAssertEqual(settled.audibleItemID, items[0].id)
        XCTAssertEqual(factory.audiblePlayingItemIDs, [items[0].id])
        XCTAssertEqual(factory.session(loadedWith: items[3].id)?.playCount ?? 0, 0)
        XCTAssertEqual(factory.maximumAudiblePlayingCount, 1)

        await engine.stop()
    }

    func testBackgroundSuspendsAudioButKeepsWarmLeasesForForegroundHandoff() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        _ = await engine.waitUntilSettled()
        var snapshot = engine.setPlaybackSuspended(true)
        XCTAssertTrue(snapshot.isPlaybackSuspended)
        XCTAssertNil(snapshot.activeItemID)
        XCTAssertNil(snapshot.audibleItemID)
        XCTAssertTrue(factory.audiblePlayingItemIDs.isEmpty)

        try await engine.update(signal(generation: 2, focused: items[1].id))
        snapshot = await engine.waitUntilSettled()
        XCTAssertTrue(snapshot.isPlaybackSuspended)
        XCTAssertEqual(snapshot.targetFocusedItemID, items[1].id)
        XCTAssertNil(snapshot.activeItemID)
        XCTAssertTrue(factory.audiblePlayingItemIDs.isEmpty)

        snapshot = engine.setPlaybackSuspended(false)
        XCTAssertFalse(snapshot.isPlaybackSuspended)
        XCTAssertEqual(snapshot.activeItemID, items[1].id)
        XCTAssertEqual(snapshot.audibleItemID, items[1].id)
        XCTAssertEqual(factory.audiblePlayingItemIDs, [items[1].id])
        XCTAssertLessThanOrEqual(snapshot.allocatedPlayerCount, 2)
        XCTAssertEqual(factory.maximumAudiblePlayingCount, 1)

        await engine.stop()
        XCTAssertTrue(factory.audiblePlayingItemIDs.isEmpty)
        XCTAssertTrue(factory.sessions.allSatisfy { $0.isMuted && !$0.isPlaying })
    }

    func testNewGenerationCancelsAndRejectsStalePlayerCompletion() async throws {
        let items = makeItems(count: 3)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory()
        let firstLoadStarted = expectation(description: "generation 1 player load started")
        let firstLoadCompletion = FeedTestLoadGate()
        defer { firstLoadCompletion.release() }
        factory.beforeLoadCompletion = { itemID in
            guard itemID == items[0].id else { return }
            firstLoadStarted.fulfill()
            // Deliberately ignore cancellation until the test releases the old
            // completion. A scheduler yield cannot guarantee this overlap.
            await firstLoadCompletion.wait()
        }
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        await fulfillment(of: [firstLoadStarted], timeout: 2)
        try await engine.update(signal(generation: 2, focused: items[1].id))
        firstLoadCompletion.release()
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
        XCTAssertEqual(factory.sessions.first?.preparationCount, 5)
        XCTAssertEqual(factory.sessions.first?.playCount, 0)

        await engine.stop()
    }

    func testPreparationRetryPolicyClampsAttemptsAndDelay() {
        let minimum = HLSFeedPlayerPreparationRetryPolicy(
            maximumAttemptCount: 0,
            retryDelay: .milliseconds(-50)
        )
        let maximum = HLSFeedPlayerPreparationRetryPolicy(
            maximumAttemptCount: 100,
            retryDelay: .seconds(10)
        )

        XCTAssertEqual(minimum.maximumAttemptCount, 1)
        XCTAssertEqual(minimum.retryDelay, .zero)
        XCTAssertEqual(maximum.maximumAttemptCount, 5)
        XCTAssertEqual(maximum.retryDelay, .milliseconds(200))
    }

    func testTransientPreparationRejectionRetriesThenPublishesWarmLease() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(preparationResults: [false, true])
        let engine = try makeEngine(
            items: items,
            policy: policy,
            factory: factory,
            playerPreparationRetryPolicy: .init(
                maximumAttemptCount: 3,
                retryDelay: .zero
            )
        )

        try await engine.update(signal(generation: 1, focused: items[0].id))
        let snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, items[0].id)
        XCTAssertEqual(snapshot.audibleItemID, items[0].id)
        XCTAssertEqual(snapshot.playback(for: items[0].id)?.phase, .focused)
        XCTAssertTrue(snapshot.failures.isEmpty)
        XCTAssertEqual(factory.sessions.first?.preparationCount, 2)

        await engine.stop()
    }

    func testCancellationStopsPreparationRetryWithoutWaitingForDelay() async throws {
        let items = makeItems(count: 1)
        let policy = try makePolicy(maximumPlayerCount: 1, prefetchItemCount: 0)
        let factory = FakeFeedSessionFactory(preparationDelay: .seconds(5))
        let engine = try makeEngine(items: items, policy: policy, factory: factory)

        try await engine.update(signal(generation: 1, focused: items[0].id))
        for _ in 0..<100 where factory.sessions.first?.preparationCount != 1 {
            await Task.yield()
        }
        XCTAssertEqual(factory.sessions.first?.preparationCount, 1)

        let clock = ContinuousClock()
        let startedAt = clock.now
        await engine.stop()

        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
        XCTAssertEqual(factory.sessions.first?.preparationCancellationCount, 1)
        XCTAssertEqual(factory.sessions.first?.preparationCount, 1)
        XCTAssertEqual(engine.snapshot.activeLoadCount, 0)
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
            let maximumAudiblePlaybackCount: Int
            let maximumPlayerPoolLimit: Int
            let allocatedSessionCount: Int
            let finalPoolOccupancy: Int
            let finalAllocatedPlayerCount: Int
            let finalActiveLoadCount: Int
            let activeObserverCount: Int
            let maximumAnalyticsObserverCount: Int
            let finalAnalyticsObserverCount: Int
            let stoppedSessionCount: Int
            let finalAudiblePlayingSessionCount: Int
            let handoffAttemptCount: UInt64
            let handoffSuccessCount: UInt64
            let handoffSuccessRate: Double
            let analyticsEnabled: Bool
            let analyticsMaximumActiveAttemptCount: Int
            let analyticsFinalActiveAttemptCount: Int
            let analyticsEmittedEventCount: UInt64
            let analyticsDroppedEventCount: UInt64
            let analyticsEmittedSummaryCount: UInt64
            let analyticsDroppedSummaryCount: UInt64
            let analyticsStaleEventCount: UInt64
        }
        let items = makeItems(count: 11)
        let policy = try makePolicy(maximumPlayerCount: 2)
        let factory = FakeFeedSessionFactory()
        let engine = try makeEngine(items: items, policy: policy, factory: factory)
        var maximumAllocatedPlayerCount = 0
        var maximumAnalyticsObserverCount = 0

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
            XCTAssertEqual(snapshot.audibleItemID, focused)
            XCTAssertEqual(snapshot.playbacks.filter(\.isAudible).count, 1)
            XCTAssertLessThanOrEqual(snapshot.maximumObservedAudiblePlaybackCount, 1)
            XCTAssertLessThanOrEqual(factory.maximumAudiblePlayingCount, 1)
            maximumAllocatedPlayerCount = max(
                maximumAllocatedPlayerCount,
                snapshot.allocatedPlayerCount
            )
            let analyticsObserverCount = factory.sessions.reduce(0) {
                $0 + $1.activeStreamingObserverCount
            }
            maximumAnalyticsObserverCount = max(
                maximumAnalyticsObserverCount,
                analyticsObserverCount
            )
            XCTAssertLessThanOrEqual(
                analyticsObserverCount,
                policy.concurrency.maximumPlayerCount
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
        XCTAssertTrue(factory.sessions.allSatisfy { $0.activeStreamingObserverCount == 0 })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.isStopped })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.isMuted && !$0.isPlaying })
        let summary = try engine.telemetry.machineReadableSummary()
        let decoded = try JSONDecoder().decode(HLSFeedTelemetry.Snapshot.self, from: summary)
        XCTAssertEqual(decoded, engine.telemetry.snapshot)
        XCTAssertGreaterThanOrEqual(decoded.handoffSuccessCount, 500)
        let handoffAttemptCount = decoded.paths.reduce(UInt64(0)) {
            $0 &+ $1.handoffAttemptCount
        }
        let handoffSuccessRate = Double(decoded.handoffSuccessCount) / Double(handoffAttemptCount)
        XCTAssertGreaterThanOrEqual(handoffSuccessRate, 0.99)
        let analyticsSnapshot = engine.analytics.snapshot
        XCTAssertTrue(engine.analytics.isEnabled)
        XCTAssertEqual(analyticsSnapshot.activeAttemptCount, 0)
        XCTAssertGreaterThan(analyticsSnapshot.emittedEventCount, 0)
        XCTAssertGreaterThan(analyticsSnapshot.emittedSummaryCount, 0)
        XCTAssertEqual(analyticsSnapshot.staleEventCount, 0)
        try QualificationArtifact.write(
            EnduranceReport(
                transitionCount: 500,
                maximumPlayerPoolOccupancy: decoded.resources.maximumPlayerPoolOccupancy,
                maximumAllocatedPlayerCount: maximumAllocatedPlayerCount,
                maximumAudiblePlaybackCount: factory.maximumAudiblePlayingCount,
                maximumPlayerPoolLimit: policy.concurrency.maximumPlayerCount,
                allocatedSessionCount: factory.sessions.count,
                finalPoolOccupancy: engine.snapshot.poolOccupancy,
                finalAllocatedPlayerCount: engine.snapshot.allocatedPlayerCount,
                finalActiveLoadCount: engine.snapshot.activeLoadCount,
                activeObserverCount: factory.sessions.reduce(0) { $0 + $1.activeStateObserverCount },
                maximumAnalyticsObserverCount: maximumAnalyticsObserverCount,
                finalAnalyticsObserverCount: factory.sessions.reduce(0) {
                    $0 + $1.activeStreamingObserverCount
                },
                stoppedSessionCount: factory.sessions.filter(\.isStopped).count,
                finalAudiblePlayingSessionCount: factory.audiblePlayingItemIDs.count,
                handoffAttemptCount: handoffAttemptCount,
                handoffSuccessCount: decoded.handoffSuccessCount,
                handoffSuccessRate: handoffSuccessRate,
                analyticsEnabled: engine.analytics.isEnabled,
                analyticsMaximumActiveAttemptCount: analyticsSnapshot.maximumActiveAttemptCount,
                analyticsFinalActiveAttemptCount: analyticsSnapshot.activeAttemptCount,
                analyticsEmittedEventCount: analyticsSnapshot.emittedEventCount,
                analyticsDroppedEventCount: analyticsSnapshot.droppedEventCount,
                analyticsEmittedSummaryCount: analyticsSnapshot.emittedSummaryCount,
                analyticsDroppedSummaryCount: analyticsSnapshot.droppedSummaryCount,
                analyticsStaleEventCount: analyticsSnapshot.staleEventCount
            ),
            named: "hls-feed-engine-endurance.json"
        )
    }

    private func makeEngine(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        factory: FakeFeedSessionFactory,
        telemetry: HLSFeedTelemetry? = nil,
        analytics: PlaybackAnalyticsTimeline? = nil,
        sharedCache: HLSSegmentCache? = nil,
        playerPreparationRetryPolicy: HLSFeedPlayerPreparationRetryPolicy = .automaticFeed
    ) throws -> HLSFeedEngine {
        let backend = ImmediateFeedPreparationBackend()
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)
        return try HLSFeedEngine(
            items: items,
            policy: policy,
            coordinator: coordinator,
            sessionFactory: { configuration in factory.make(configuration: configuration) },
            telemetry: telemetry ?? HLSFeedTelemetry(),
            analytics: analytics ?? PlaybackAnalyticsTimeline(),
            sharedCache: sharedCache,
            playerPreparationRetryPolicy: playerPreparationRetryPolicy
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
    var beforeLoadCompletion: (@MainActor (FeedItemID) async -> Void)?
    let loadDelay: Duration
    let failingItemIDs: Set<FeedItemID>
    let failsPreparation: Bool
    let preparationResults: [Bool]?
    let preparationDelay: Duration
    let usesUnstartedPlatformPlayer: Bool
    private(set) var sessions: [FakeFeedPlayerSession] = []
    private(set) var maximumAudiblePlayingCount = 0

    init(
        loadDelay: Duration = .zero,
        failingItemIDs: Set<FeedItemID> = [],
        failsPreparation: Bool = false,
        preparationResults: [Bool]? = nil,
        preparationDelay: Duration = .zero,
        usesUnstartedPlatformPlayer: Bool = false
    ) {
        self.loadDelay = loadDelay
        self.failingItemIDs = failingItemIDs
        self.failsPreparation = failsPreparation
        self.preparationResults = preparationResults
        self.preparationDelay = preparationDelay
        self.usesUnstartedPlatformPlayer = usesUnstartedPlatformPlayer
    }

    func make(configuration: ProxyPlayerConfiguration) -> FakeFeedPlayerSession {
        let session = FakeFeedPlayerSession(
            configuration: configuration,
            loadDelay: loadDelay,
            failingItemIDs: failingItemIDs,
            failsPreparation: failsPreparation,
            preparationResults: preparationResults,
            preparationDelay: preparationDelay,
            platformPlayer: usesUnstartedPlatformPlayer ? AVPlayer() : nil
        )
        session.onPlaybackMutation = { [weak self] in
            self?.captureAudiblePlaybackCount()
        }
        session.beforeLoadCompletion = beforeLoadCompletion
        sessions.append(session)
        captureAudiblePlaybackCount()
        return session
    }

    func session(loadedWith itemID: FeedItemID) -> FakeFeedPlayerSession? {
        sessions.first { $0.loadedItemID == itemID }
    }

    var audiblePlayingItemIDs: [FeedItemID] {
        sessions.compactMap { session in
            guard session.isPlaying, !session.isMuted else { return nil }
            return session.loadedItemID
        }
    }

    private func captureAudiblePlaybackCount() {
        maximumAudiblePlayingCount = max(
            maximumAudiblePlayingCount,
            sessions.filter { $0.isPlaying && !$0.isMuted }.count
        )
    }
}

@MainActor
private final class FakeFeedPlayerSession: HLSFeedPlayerSession {
    var beforeLoadCompletion: (@MainActor (FeedItemID) async -> Void)?
    private(set) var state = PlayerState()
    let feedPlatformPlayer: AVPlayer?
    private(set) var configuration: ProxyPlayerConfiguration
    private(set) var loadedItemID: FeedItemID?
    private(set) var loadedStreamKind: FeedStreamKind?
    private(set) var loadedClipCount = 0
    private(set) var loadCount = 0
    private(set) var preparationCount = 0
    private(set) var preparationCancellationCount = 0
    private(set) var playCount = 0
    private(set) var playBeforePreparationCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var restartCount = 0
    private(set) var isStopped = false
    private(set) var isMuted = true
    private(set) var isPlaying = false
    private(set) var activeStateObserverCount = 0
    var onPlaybackMutation: (@MainActor () -> Void)?

    private let loadDelay: Duration
    private let failingItemIDs: Set<FeedItemID>
    private let failsPreparation: Bool
    private var preparationResults: [Bool]
    private let preparationDelay: Duration
    private var continuations: [UUID: AsyncStream<PlayerState>.Continuation] = [:]
    private var streamingContinuations: [
        UUID: AsyncStream<HLSStreamingTelemetry.Snapshot>.Continuation
    ] = [:]
    private var streamingSnapshot = HLSStreamingTelemetry.Snapshot.empty

    var activeStreamingObserverCount: Int { streamingContinuations.count }

    init(
        configuration: ProxyPlayerConfiguration,
        loadDelay: Duration,
        failingItemIDs: Set<FeedItemID>,
        failsPreparation: Bool,
        preparationResults: [Bool]?,
        preparationDelay: Duration,
        platformPlayer: AVPlayer?
    ) {
        self.configuration = configuration
        self.loadDelay = loadDelay
        self.failingItemIDs = failingItemIDs
        self.failsPreparation = failsPreparation
        self.preparationResults = preparationResults ?? []
        self.preparationDelay = preparationDelay
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
        if let loadedItemID { await beforeLoadCompletion?(loadedItemID) }
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

    func prepareForImmediatePlayback(
        retryPolicy: HLSFeedPlayerPreparationRetryPolicy
    ) async -> Bool {
        for attempt in 1...retryPolicy.maximumAttemptCount {
            preparationCount += 1
            if preparationDelay > .zero {
                do {
                    try await Task.sleep(for: preparationDelay)
                } catch {
                    preparationCancellationCount += 1
                    return false
                }
            }
            let didPrepare = preparationResults.isEmpty
                ? !failsPreparation
                : preparationResults.removeFirst()
            if didPrepare { return true }
            guard attempt < retryPolicy.maximumAttemptCount else { return false }
            do {
                try await Task.sleep(for: retryPolicy.retryDelay * attempt)
            } catch {
                preparationCancellationCount += 1
                return false
            }
        }
        return false
    }

    func play() {
        playCount += 1
        if preparationCount == 0 { playBeforePreparationCount += 1 }
        isPlaying = true
        onPlaybackMutation?()
    }
    func pause() {
        pauseCount += 1
        isPlaying = false
        onPlaybackMutation?()
    }
    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        onPlaybackMutation?()
    }
    func setPlaybackRate(_ rate: Float) {}
    func jumpToLive() async throws {}
    func seek(secondsBehindLiveEdge: TimeInterval) async throws {}

    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        self.configuration = configuration
    }

    func stopAndWait() async {
        stopCount += 1
        isStopped = true
        isPlaying = false
        isMuted = true
        onPlaybackMutation?()
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

/// A single-load test barrier that intentionally does not react to task
/// cancellation, so the stale-completion path is exercised deterministically.
@MainActor
private final class FeedTestLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class PlaybackAnalyticsPerformanceTests: XCTestCase {
    private struct Run: Sendable {
        let firstFrameP95Milliseconds: Double
        let cpuPercent: Double
        let emittedEventCount: UInt64
        let emittedSummaryCount: UInt64
    }

    private struct OverheadReport: Codable {
        let configuration: String
        let measuredTransitionCountPerRun: Int
        let warmupTransitionCountPerRun: Int
        let runCountPerMode: Int
        let disabledFirstFrameP95Milliseconds: Double
        let enabledFirstFrameP95Milliseconds: Double
        let firstFrameP95OverheadMilliseconds: Double
        let firstFrameP95OverheadLimitMilliseconds: Double
        let disabledCPUPercent: Double
        let enabledCPUPercent: Double
        let cpuOverheadPercentagePoints: Double
        let cpuOverheadLimitPercentagePoints: Double
        let enabledEmittedEventCount: UInt64
        let enabledEmittedSummaryCount: UInt64
        let disabledEmittedEventCount: UInt64
        let disabledEmittedSummaryCount: UInt64
    }

    func testAnalyticsOverheadStaysBelowFirstFrameAndCPUBudgetsAfterWarmup() async throws {
        let measuredTransitions = 1_000
        let warmupTransitions = 100
        let firstFrameLimitMilliseconds = 5.0
        let cpuLimitPercentagePoints = 2.0
        let runOrder = [false, true, true, false, false, true]
        var enabledRuns: [Run] = []
        var disabledRuns: [Run] = []

        for isEnabled in runOrder {
            let run = try await measureEngine(
                analyticsEnabled: isEnabled,
                measuredTransitions: measuredTransitions,
                warmupTransitions: warmupTransitions
            )
            if isEnabled {
                enabledRuns.append(run)
            } else {
                disabledRuns.append(run)
            }
        }

        let disabledFirstFrameP95 = median(
            disabledRuns.map(\.firstFrameP95Milliseconds)
        )
        let enabledFirstFrameP95 = median(
            enabledRuns.map(\.firstFrameP95Milliseconds)
        )
        let disabledCPUPercent = median(disabledRuns.map(\.cpuPercent))
        let enabledCPUPercent = median(enabledRuns.map(\.cpuPercent))
        let firstFrameOverhead = max(0, enabledFirstFrameP95 - disabledFirstFrameP95)
        let cpuOverhead = max(0, enabledCPUPercent - disabledCPUPercent)

        XCTAssertLessThanOrEqual(
            firstFrameOverhead,
            firstFrameLimitMilliseconds,
            "Analytics added \(firstFrameOverhead) ms to local-fixture first-frame p95"
        )
        XCTAssertLessThanOrEqual(
            cpuOverhead,
            cpuLimitPercentagePoints,
            "Analytics added \(cpuOverhead) CPU percentage points after warmup"
        )
        XCTAssertTrue(enabledRuns.allSatisfy { $0.emittedEventCount > 0 })
        XCTAssertTrue(enabledRuns.allSatisfy { $0.emittedSummaryCount > 0 })
        XCTAssertTrue(disabledRuns.allSatisfy { $0.emittedEventCount == 0 })
        XCTAssertTrue(disabledRuns.allSatisfy { $0.emittedSummaryCount == 0 })

        try QualificationArtifact.write(
            OverheadReport(
                configuration: artifactConfiguration,
                measuredTransitionCountPerRun: measuredTransitions,
                warmupTransitionCountPerRun: warmupTransitions,
                runCountPerMode: enabledRuns.count,
                disabledFirstFrameP95Milliseconds: disabledFirstFrameP95,
                enabledFirstFrameP95Milliseconds: enabledFirstFrameP95,
                firstFrameP95OverheadMilliseconds: firstFrameOverhead,
                firstFrameP95OverheadLimitMilliseconds: firstFrameLimitMilliseconds,
                disabledCPUPercent: disabledCPUPercent,
                enabledCPUPercent: enabledCPUPercent,
                cpuOverheadPercentagePoints: cpuOverhead,
                cpuOverheadLimitPercentagePoints: cpuLimitPercentagePoints,
                enabledEmittedEventCount: enabledRuns.reduce(0) {
                    $0 + $1.emittedEventCount
                },
                enabledEmittedSummaryCount: enabledRuns.reduce(0) {
                    $0 + $1.emittedSummaryCount
                },
                disabledEmittedEventCount: disabledRuns.reduce(0) {
                    $0 + $1.emittedEventCount
                },
                disabledEmittedSummaryCount: disabledRuns.reduce(0) {
                    $0 + $1.emittedSummaryCount
                }
            ),
            named: "hls-playback-analytics-overhead-\(artifactConfiguration).json"
        )
    }

    private func measureEngine(
        analyticsEnabled: Bool,
        measuredTransitions: Int,
        warmupTransitions: Int
    ) async throws -> Run {
        let items = (0..<11).map { index in
            FeedPlaybackItem(
                id: FeedItemID(rawValue: "analytics-overhead-\(index)"),
                source: .stream(
                    url: URL(fileURLWithPath: "/fixtures/analytics-overhead-\(index).m3u8"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 1_024
            )
        }
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.aheadItemCount = 1
        policy.prefetch.behindItemCount = 0
        policy.budget.maximumResidentItems = 2
        policy.concurrency.maximumPlayerCount = 2
        policy.eviction.offscreenGracePeriod = 0
        policy.lowPower.maximumPrefetchItems = 1
        policy.lowPower.maximumPlayerCount = 2
        policy = try policy.validated()
        let coordinator = try FeedCoordinator(
            items: items,
            policy: policy,
            backend: ImmediateFeedPreparationBackend()
        )
        let factory = FakeFeedSessionFactory()
        let analytics = PlaybackAnalyticsTimeline(configuration: .init(
            isEnabled: analyticsEnabled,
            eventBufferCapacity: 128,
            summaryBufferCapacity: 64,
            maximumActiveAttemptCount: 4
        ))
        let engine = try HLSFeedEngine(
            items: items,
            policy: policy,
            coordinator: coordinator,
            sessionFactory: { configuration in factory.make(configuration: configuration) },
            analytics: analytics
        )
        let clock = ContinuousClock()
        var firstFrameSamples: [Double] = []
        firstFrameSamples.reserveCapacity(measuredTransitions)
        var measuredWallStart: ContinuousClock.Instant?
        var measuredCPUStart = 0.0
        let totalTransitions = warmupTransitions + measuredTransitions

        for step in 0..<totalTransitions {
            if step == warmupTransitions {
                measuredWallStart = clock.now
                measuredCPUStart = processCPUSeconds()
            }
            let focused = items[step % items.count].id
            let startedAt = clock.now
            try await engine.update(FeedViewportSignal(
                generation: .init(rawValue: UInt64(step + 1)),
                focusedItemID: focused,
                visibleItems: [.init(
                    itemID: focused,
                    fraction: 1,
                    distanceInViewports: 0
                )],
                velocityInViewportsPerSecond: step.isMultiple(of: 2) ? 8 : -8,
                observedAt: .milliseconds(Int64(step))
            ))
            let settled = await engine.waitUntilSettled()
            XCTAssertEqual(settled.activeItemID, focused)
            XCTAssertEqual(settled.playback(for: focused)?.hasStartedPlayback, true)
            if step >= warmupTransitions {
                firstFrameSamples.append(milliseconds(startedAt.duration(to: clock.now)))
            }
        }

        let wallStart = try XCTUnwrap(measuredWallStart)
        let wallSeconds = seconds(wallStart.duration(to: clock.now))
        let cpuSeconds = max(0, processCPUSeconds() - measuredCPUStart)
        let analyticsObserverCount = factory.sessions.reduce(0) {
            $0 + $1.activeStreamingObserverCount
        }
        if analyticsEnabled {
            XCTAssertLessThanOrEqual(
                analyticsObserverCount,
                policy.concurrency.maximumPlayerCount
            )
        } else {
            XCTAssertEqual(analyticsObserverCount, 0)
        }
        await engine.stop()
        await Task.yield()
        XCTAssertEqual(engine.snapshot.poolOccupancy, 0)
        XCTAssertEqual(engine.snapshot.allocatedPlayerCount, 0)
        XCTAssertEqual(engine.snapshot.activeLoadCount, 0)
        XCTAssertTrue(factory.sessions.allSatisfy { $0.activeStateObserverCount == 0 })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.activeStreamingObserverCount == 0 })
        XCTAssertTrue(factory.sessions.allSatisfy { $0.isStopped })

        return Run(
            firstFrameP95Milliseconds: percentile(firstFrameSamples, 0.95),
            cpuPercent: wallSeconds > 0 ? cpuSeconds / wallSeconds * 100 : 0,
            emittedEventCount: analytics.snapshot.emittedEventCount,
            emittedSummaryCount: analytics.snapshot.emittedSummaryCount
        )
    }

    private var artifactConfiguration: String {
        ProcessInfo.processInfo.environment["HLS_ANALYTICS_QUALIFICATION_CONFIGURATION"]
            ?? "debug"
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(quantile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func processCPUSeconds() -> Double {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    private func milliseconds(_ duration: Duration) -> Double {
        seconds(duration) * 1_000
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
