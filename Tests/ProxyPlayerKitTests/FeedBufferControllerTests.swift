#if canImport(Observation)
import XCTest
@testable import ProxyPlayerKit
import HLSCore

@MainActor
final class FeedBufferControllerTests: XCTestCase {
    func testKeepsVisiblePlayerActiveAndNeighborsWarm() async {
        let policy = FeedBufferPolicy(
            maxLiveNeighbors: 1,
            maxVODNeighbors: 1,
            activeBufferSeconds: 8,
            warmBufferSeconds: 3,
            coldBufferSeconds: 0,
            totalMemoryBudgetMegabytes: 128,
            cooldownDelay: 0
        )
        let controller = FeedBufferController(policy: policy)

        let players = [
            StubPlayer(identifier: "live-0"),
            StubPlayer(identifier: "live-1"),
            StubPlayer(identifier: "vod-2"),
            StubPlayer(identifier: "live-3")
        ]

        _ = controller.register(player: players[0], descriptor: .make(index: 0, kind: .live, urlIdentifier: "a"))
        _ = controller.register(player: players[1], descriptor: .make(index: 1, kind: .live, urlIdentifier: "b"))
        _ = controller.register(player: players[2], descriptor: .make(index: 2, kind: .vod, urlIdentifier: "c"))
        _ = controller.register(player: players[3], descriptor: .make(index: 3, kind: .live, urlIdentifier: "d"))

        controller.updateVisibleIndex(1)
        let expectations = makeExpectations(players: players)
        await fulfillment(of: expectations, timeout: 1)

        controller.updateVisibleIndex(3)
        let stopExpectation = waitUntil("evicted neighbor stops") { players[0].stopCallCount >= 1 }
        await fulfillment(of: [stopExpectation], timeout: 1)
    }

    func testTelemetryEmitsWarmSetChanges() async {
        let policy = FeedBufferPolicy(
            maxLiveNeighbors: 1,
            maxVODNeighbors: 1,
            activeBufferSeconds: 8,
            warmBufferSeconds: 3,
            coldBufferSeconds: 0,
            totalMemoryBudgetMegabytes: 128,
            cooldownDelay: 0
        )

        let recorder = TelemetryRecorder()
        let telemetry = FeedBufferTelemetry(
            onWarmSetChanged: { snapshots in
                Task { @MainActor in
                    recorder.recordSnapshots(snapshots)
                }
            },
            onEvent: { event in
                Task { @MainActor in
                    recorder.recordEvent(event)
                }
            }
        )

        let controller = FeedBufferController(policy: policy, telemetry: telemetry)
        let playerA = StubPlayer(identifier: "live-0")
        let playerB = StubPlayer(identifier: "vod-1")

        let handleA = controller.register(player: playerA, descriptor: .make(index: 0, kind: .live, urlIdentifier: "a"))
        _ = controller.register(player: playerB, descriptor: .make(index: 1, kind: .vod, urlIdentifier: "b"))

        controller.updateVisibleIndex(0)
        await Task.yield()
        controller.updateVisibleIndex(1)
        await Task.yield()

        XCTAssertGreaterThanOrEqual(recorder.warmSnapshots.count, 1)
        XCTAssertTrue(recorder.events.contains(where: { event in
            if case .enteredWarmSet(let descriptor) = event {
                return descriptor.id == "vod-1"
            }
            return false
        }))

        controller.unregister(handle: handleA)
        await Task.yield()
        XCTAssertTrue(recorder.events.contains(where: { event in
            if case .exitedWarmSet(let descriptor) = event {
                return descriptor.id == "live-0"
            }
            return false
        }))
    }

    func testReturningToPlayerBeforeCooldownFinishesDoesNotStopIt() async throws {
        let controller = FeedBufferController(policy: .init(
            maxLiveNeighbors: 0,
            maxVODNeighbors: 0,
            cooldownDelay: 0.1
        ))
        let first = StubPlayer(identifier: "vod-0")
        let second = StubPlayer(identifier: "vod-1")

        _ = controller.register(player: first, descriptor: .make(index: 0, kind: .vod, urlIdentifier: "a"))
        _ = controller.register(player: second, descriptor: .make(index: 1, kind: .vod, urlIdentifier: "b"))
        controller.updateVisibleIndex(0)
        await Task.yield()

        controller.updateVisibleIndex(1)
        controller.updateVisibleIndex(0)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(first.stopCallCount, 0)
        XCTAssertGreaterThanOrEqual(first.playCallCount, 2)
    }

    func testChangingURLWhileLoadingPreparesLatestDescriptor() async {
        let controller = FeedBufferController(policy: .init(cooldownDelay: 0))
        let player = StubPlayer(identifier: "vod-0", loadDelayNanoseconds: 100_000_000)
        let original = FeedPlayerDescriptor.make(index: 0, kind: .vod, urlIdentifier: "original")
        let replacement = FeedPlayerDescriptor.make(index: 0, kind: .vod, urlIdentifier: "replacement")

        let handle = controller.register(player: player, descriptor: original)
        controller.updateVisibleIndex(0)
        await Task.yield()
        controller.updateDescriptor(for: handle, descriptor: replacement)

        let expectation = waitUntil("replacement URL loads") {
            player.loadedURLs.contains(replacement.url)
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(player.loadedURLs.last, replacement.url)
    }

    func testReregisteringPlayerDuringCancelledLoadDoesNotStopNewOwner() async {
        let controller = FeedBufferController(policy: .init(cooldownDelay: 0))
        let player = StubPlayer(identifier: "vod-0", loadDelayNanoseconds: 100_000_000)
        let descriptor = FeedPlayerDescriptor.make(index: 0, kind: .vod, urlIdentifier: "stream")

        let firstHandle = controller.register(player: player, descriptor: descriptor)
        controller.updateVisibleIndex(0)
        await Task.yield()
        controller.unregister(handle: firstHandle)
        _ = controller.register(player: player, descriptor: descriptor)

        let expectation = waitUntil("re-registered player loads") {
            player.loadCallCount >= 2
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(player.stopCallCount, 1)
    }

    func testVisibleItemIDCanBeSetBeforeRegistrationAndCleared() async {
        let controller = FeedBufferController(policy: .init(cooldownDelay: 0))
        let player = StubPlayer(identifier: "vod-4")
        let descriptor = FeedPlayerDescriptor.make(index: 4, kind: .vod, urlIdentifier: "target")

        controller.visibleItemID = descriptor.id
        _ = controller.register(player: player, descriptor: descriptor)

        let playExpectation = waitUntil("registered visible player plays") {
            player.playCallCount >= 1
        }
        await fulfillment(of: [playExpectation], timeout: 1)

        controller.visibleItemID = nil
        let stopExpectation = waitUntil("cleared visible player stops") {
            player.stopCallCount >= 1
        }
        await fulfillment(of: [stopExpectation], timeout: 1)
    }

    func testUnregisteringActivePlayerPromotesNearestRegisteredPlayer() async {
        let controller = FeedBufferController(policy: .init(
            maxLiveNeighbors: 0,
            maxVODNeighbors: 1,
            cooldownDelay: 0
        ))
        let first = StubPlayer(identifier: "vod-0")
        let second = StubPlayer(identifier: "vod-1")
        let firstHandle = controller.register(
            player: first,
            descriptor: .make(index: 0, kind: .vod, urlIdentifier: "a")
        )
        _ = controller.register(player: second, descriptor: .make(index: 1, kind: .vod, urlIdentifier: "b"))

        controller.updateVisibleIndex(0)
        await Task.yield()
        controller.unregister(handle: firstHandle)

        let expectation = waitUntil("nearest player promoted") {
            second.playCallCount >= 1
        }
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testMemoryBudgetEvictsLowestRankedWarmPlayer() async {
        let controller = FeedBufferController(policy: .init(
            maxLiveNeighbors: 1,
            maxVODNeighbors: 1,
            totalMemoryBudgetMegabytes: 160,
            cooldownDelay: 0
        ))
        let previous = StubPlayer(identifier: "live-0")
        let active = StubPlayer(identifier: "live-1")
        let next = StubPlayer(identifier: "vod-2")

        _ = controller.register(player: previous, descriptor: .make(
            index: 0,
            kind: .live,
            urlIdentifier: "a",
            estimatedMemoryMegabytes: 80
        ))
        _ = controller.register(player: active, descriptor: .make(
            index: 1,
            kind: .live,
            urlIdentifier: "b",
            estimatedMemoryMegabytes: 80
        ))
        _ = controller.register(player: next, descriptor: .make(
            index: 2,
            kind: .vod,
            urlIdentifier: "c",
            estimatedMemoryMegabytes: 80
        ))
        controller.updateVisibleIndex(1)

        let expectation = waitUntil("budgeted players load") {
            previous.loadCallCount >= 1 && active.loadCallCount >= 1
        }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(next.loadCallCount, 0)
    }
}

@MainActor
private extension FeedBufferControllerTests {
    func makeExpectations(players: [StubPlayer]) -> [XCTestExpectation] {
        [
            waitUntil("active plays") { players[1].playCallCount >= 1 },
            waitUntil("active loads") { players[1].loadCallCount >= 1 },
            waitUntil("previous pauses") { players[0].pauseCallCount >= 1 },
            waitUntil("previous loads") { players[0].loadCallCount >= 1 },
            waitUntil("next pauses") { players[2].pauseCallCount >= 1 },
            waitUntil("next loads") { players[2].loadCallCount >= 1 }
        ]
    }

    func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) -> XCTestExpectation {
        let expectation = expectation(description: description)
        Task { @MainActor in
            while !condition() {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            expectation.fulfill()
        }
        return expectation
    }
}

private extension FeedPlayerDescriptor {
    static func make(
        index: Int,
        kind: FeedPlayerDescriptor.StreamKind,
        urlIdentifier: String,
        estimatedMemoryMegabytes: Int = 32
    ) -> FeedPlayerDescriptor {
        FeedPlayerDescriptor(
            id: "\(kind == .live ? "live" : "vod")-\(index)",
            index: index,
            kind: kind,
            priority: 0,
            url: URL(string: "https://example.com/\(urlIdentifier).m3u8")!,
            estimatedMemoryMegabytes: estimatedMemoryMegabytes
        )
    }
}

@MainActor
private final class StubPlayer: FeedBufferControllable {
    private var storedConfiguration: ProxyPlayerConfiguration
    private(set) var stateValue = PlayerState()

    var configuration: ProxyPlayerConfiguration { storedConfiguration }
    var state: PlayerState { stateValue }

    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var updateConfigurationCallCount = 0
    private(set) var loadedURLs: [URL] = []
    let identifier: String
    let loadDelayNanoseconds: UInt64

    init(
        identifier: String,
        configuration: ProxyPlayerConfiguration = .init(),
        loadDelayNanoseconds: UInt64 = 0
    ) {
        self.identifier = identifier
        self.storedConfiguration = configuration
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }

    func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy) async {
        loadCallCount += 1
        loadedURLs.append(remoteURL)
        if loadDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        stateValue = PlayerState(status: .ready, bufferDepthSeconds: stateValue.bufferDepthSeconds + 1, qualityDescription: "test")
    }

    func play() {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func stop() {
        stopCallCount += 1
        stateValue = PlayerState(status: .idle)
    }

    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        updateConfigurationCallCount += 1
        storedConfiguration = configuration
    }
}

@MainActor
private final class TelemetryRecorder {
    private(set) var warmSnapshots: [[FeedPlayerSnapshot]] = []
    private(set) var events: [FeedBufferEvent] = []

    func recordSnapshots(_ snapshots: [FeedPlayerSnapshot]) {
        warmSnapshots.append(snapshots)
    }

    func recordEvent(_ event: FeedBufferEvent) {
        events.append(event)
    }
}
#endif
