import Foundation
import XCTest
@testable import ProxyPlayerKit

final class HLSFeedBackgroundWarmingTests: XCTestCase {
    func testPolicyValidationReportsEveryInvalidBoundInStableOrder() throws {
        let policy = makePolicy(
            maximumItemCount: 0,
            maximumLeadingSegmentsPerItem: 0,
            maximumEstimatedByteCount: 0,
            maximumConcurrentPreparations: 0,
            maximumExecutionTime: .zero,
            minimumRemainingCacheValidity: .seconds(-1)
        )

        XCTAssertThrowsError(try policy.validated()) { error in
            XCTAssertEqual(
                (error as? HLSFeedBackgroundWarmingPolicy.ValidationError)?.issues,
                [
                    .itemLimitMustBePositive,
                    .segmentLimitMustBePositive,
                    .byteLimitMustBePositive,
                    .concurrencyLimitMustBePositive,
                    .executionTimeMustBePositive,
                    .cacheValidityMustBeNonnegative,
                ]
            )
        }
        XCTAssertEqual(HLSFeedBackgroundWarmingPolicy.shortFormFeed.maximumItemCount, 2)
        XCTAssertEqual(
            HLSFeedBackgroundWarmingPolicy.shortFormFeed.maximumConcurrentPreparations,
            1
        )
        XCTAssertEqual(
            HLSFeedBackgroundWarmingPolicy.shortFormFeed.privacy,
            .aggregateOnly
        )
    }

    func testAdmissionEnforcesItemSegmentByteAndConcurrencyCaps() async throws {
        let backend = BackgroundPreparingFake(delay: .milliseconds(20))
        let policy = makePolicy(
            maximumItemCount: 3,
            maximumLeadingSegmentsPerItem: 2,
            maximumEstimatedByteCount: 250,
            maximumConcurrentPreparations: 2
        )
        let warmer = try HLSFeedBackgroundWarmer(policy: policy, backend: backend)
        let request = makeRequest(items: makeItems(count: 4, estimatedBytes: 100))

        let result = await warmer.warm(request)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.candidateItemCount, 4)
        XCTAssertEqual(result.admittedItemCount, 2)
        XCTAssertEqual(result.skippedBudgetItemCount, 2)
        XCTAssertEqual(result.admittedEstimatedByteCount, 200)
        XCTAssertEqual(result.preparedLeadingSegmentCount, 4)
        XCTAssertEqual(result.maximumConcurrentPreparationCount, 2)
        let audit = await backend.audit()
        XCTAssertEqual(audit.requests.count, 2)
        XCTAssertEqual(Set(audit.requests.map(\.maximumLeadingSegments)), [2])
        XCTAssertEqual(Set(audit.requests.map(\.maximumConcurrentFetches)), [1])
        XCTAssertEqual(audit.maximumActiveCount, 2)

        let snapshot = await warmer.snapshot()
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertEqual(snapshot.admittedRequestCount, 1)
        XCTAssertEqual(snapshot.admittedItemCount, 2)
        XCTAssertEqual(snapshot.skippedBudgetItemCount, 2)
        XCTAssertEqual(snapshot.count(for: .completed), 1)
        XCTAssertEqual(snapshot.maximumObservedConcurrentPreparations, 2)
    }

    func testProductionPreparationHonorsPerRequestFetchConcurrency() async throws {
        let origin = try FeedFixtureOrigin(profile: .init(responseDelay: .milliseconds(15)))
        try await origin.start()
        defer { origin.stop() }
        var feedPolicy = FeedPlaybackPolicy.shortFormFeed
        feedPolicy.prefetch.aheadItemCount = 0
        feedPolicy.prefetch.behindItemCount = 0
        feedPolicy.prefetch.maximumLeadingSegments = 2
        feedPolicy.budget.maximumResidentItems = 1
        feedPolicy.concurrency.maximumConcurrentPreparations = 1
        feedPolicy.concurrency.maximumConcurrentFetches = 6
        feedPolicy.lowPower.maximumPrefetchItems = 0
        feedPolicy.lowPower.maximumLeadingSegments = 2
        feedPolicy.lowPower.maximumConcurrentPreparations = 1
        let backend = try HLSFeedPreparationBackend(
            policy: feedPolicy,
            allowsInsecureManifests: true
        )
        let item = FeedPlaybackItem(
            id: "bounded-fetches",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "short-a"),
                kind: .videoOnDemand
            ),
            estimatedPreparationBytes: 1_024
        )

        let prepared = try await backend.prepare(.init(
            item: item,
            generation: .init(rawValue: 1),
            role: .predicted,
            maximumLeadingSegments: 2,
            maximumConcurrentFetches: 1
        ))

        XCTAssertEqual(prepared.leadingSegmentCount, 2)
        XCTAssertLessThanOrEqual(
            origin.timelineSnapshot().map(\.activeRequests).max() ?? 0,
            1
        )
    }

    func testLowPowerAndDisallowedNetworkConditionsDenyBeforeBackendWork() async throws {
        let backend = BackgroundPreparingFake()
        let warmer = try HLSFeedBackgroundWarmer(policy: makePolicy(), backend: backend)
        let item = makeItems(count: 1)[0]
        let cases: [
            (HLSFeedBackgroundEnvironment, HLSFeedBackgroundWarmingSnapshot.Outcome)
        ] = [
            (.init(networkInterface: .unavailable), .deniedOffline),
            (.init(networkInterface: .cellular), .deniedCellular),
            (.init(networkInterface: .wifi, isConstrained: true), .deniedConstrained),
            (.init(networkInterface: .wifi, isExpensive: true), .deniedExpensive),
            (.init(networkInterface: .wifi, isLowPowerModeEnabled: true), .deniedLowPower),
        ]

        for (environment, expected) in cases {
            let result = await warmer.warm(makeRequest(items: [item], environment: environment))
            XCTAssertEqual(result.outcome, expected)
            XCTAssertEqual(result.admittedItemCount, 0)
        }

        let deniedAudit = await backend.audit()
        XCTAssertEqual(deniedAudit.requests.count, 0)
        let snapshot = await warmer.snapshot()
        XCTAssertEqual(snapshot.requestCount, 5)
        XCTAssertEqual(snapshot.admittedRequestCount, 0)
        for (_, expected) in cases {
            XCTAssertEqual(snapshot.count(for: expected), 1)
        }
    }

    func testExplicitPolicyCanAdmitLowPowerCellularConstrainedExpensiveWork() async throws {
        let backend = BackgroundPreparingFake()
        let policy = makePolicy(
            allowsCellularAccess: true,
            allowsConstrainedNetworkAccess: true,
            allowsExpensiveNetworkAccess: true,
            allowsLowPowerMode: true
        )
        let warmer = try HLSFeedBackgroundWarmer(policy: policy, backend: backend)
        let environment = HLSFeedBackgroundEnvironment(
            networkInterface: .cellular,
            isConstrained: true,
            isExpensive: true,
            isLowPowerModeEnabled: true
        )

        let result = await warmer.warm(makeRequest(
            items: makeItems(count: 1),
            environment: environment
        ))

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.admittedItemCount, 1)
        let audit = await backend.audit()
        XCTAssertEqual(audit.requests.count, 1)
    }

    func testFreshCacheIsSkippedWhileNearExpiryAndStaleCandidatesRevalidate() async throws {
        let backend = BackgroundPreparingFake()
        let policy = makePolicy(minimumRemainingCacheValidity: .seconds(30))
        let warmer = try HLSFeedBackgroundWarmer(policy: policy, backend: backend)
        let items = makeItems(count: 3)
        let request = HLSFeedBackgroundWarmingRequest(
            candidates: [
                .init(item: items[0], cacheState: .fresh(remainingValidity: .seconds(60))),
                .init(item: items[1], cacheState: .fresh(remainingValidity: .seconds(5))),
                .init(item: items[2], cacheState: .stale),
            ],
            environment: .init(networkInterface: .wifi),
            availableExecutionTime: .seconds(30)
        )

        let result = await warmer.warm(request)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.skippedFreshCacheItemCount, 1)
        XCTAssertEqual(result.admittedItemCount, 2)
        let requestedIDs = await backend.audit().requests.map(\.item.id)
        XCTAssertEqual(requestedIDs, [items[1].id, items[2].id])
    }

    func testAlreadyExpiredRequestNeverStartsWork() async throws {
        let backend = BackgroundPreparingFake()
        let warmer = try HLSFeedBackgroundWarmer(policy: makePolicy(), backend: backend)

        let result = await warmer.warm(makeRequest(
            items: makeItems(count: 1),
            availableExecutionTime: .zero
        ))

        XCTAssertEqual(result.outcome, .expired)
        let audit = await backend.audit()
        let snapshot = await warmer.snapshot()
        XCTAssertEqual(audit.requests.count, 0)
        XCTAssertEqual(snapshot.count(for: .expired), 1)
    }

    func testExecutionExpirationCancelsInFlightPreparation() async throws {
        let backend = BackgroundPreparingFake(delay: .seconds(60))
        let clock = HLSFeedBackgroundWarmingClock { _ in }
        let warmer = try HLSFeedBackgroundWarmer(
            policy: makePolicy(),
            backend: backend,
            clock: clock
        )

        let result = await warmer.warm(makeRequest(items: makeItems(count: 1)))

        XCTAssertEqual(result.outcome, .expired)
        XCTAssertEqual(result.preparedItemCount, 0)
        let audit = await backend.audit()
        XCTAssertEqual(audit.cancellationCount, 1)
    }

    func testExpirationStillAccountsForWorkCompletedBeforeCancellation() async throws {
        let items = makeItems(count: 2)
        let backend = BackgroundPreparingFake(delaysByItemID: [items[1].id: .seconds(60)])
        let clock = HLSFeedBackgroundWarmingClock { _ in
            while await backend.audit().completedCount < 1 { await Task.yield() }
        }
        let warmer = try HLSFeedBackgroundWarmer(
            policy: makePolicy(maximumItemCount: 2),
            backend: backend,
            clock: clock
        )

        let result = await warmer.warm(makeRequest(items: items))
        let snapshot = await warmer.snapshot()

        XCTAssertEqual(result.outcome, .expired)
        XCTAssertEqual(result.preparedItemCount, 1)
        XCTAssertEqual(result.preparedByteCount, 100)
        XCTAssertEqual(snapshot.preparedItemCount, 1)
        XCTAssertEqual(snapshot.preparedByteCount, 100)
        let audit = await backend.audit()
        XCTAssertEqual(audit.cancellationCount, 1)
    }

    func testCallerCancellationPropagatesIntoPreparation() async throws {
        let backend = BackgroundPreparingFake(delay: .seconds(60))
        let warmer = try HLSFeedBackgroundWarmer(policy: makePolicy(), backend: backend)
        let request = makeRequest(items: makeItems(count: 1))
        let task = Task { await warmer.warm(request) }
        for _ in 0..<100 where await backend.audit().requests.isEmpty {
            await Task.yield()
        }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.preparedItemCount, 0)
        let audit = await backend.audit()
        XCTAssertEqual(audit.cancellationCount, 1)
    }

    func testConcurrentInvocationIsDeniedInsteadOfCreatingUnboundedSessions() async throws {
        let backend = BackgroundPreparingFake(delay: .seconds(60))
        let warmer = try HLSFeedBackgroundWarmer(policy: makePolicy(), backend: backend)
        let request = makeRequest(items: makeItems(count: 1))
        let first = Task { await warmer.warm(request) }
        for _ in 0..<100 where await backend.audit().requests.isEmpty {
            await Task.yield()
        }

        let second = await warmer.warm(makeRequest(items: makeItems(count: 1)))
        first.cancel()
        _ = await first.value

        XCTAssertEqual(second.outcome, .deniedBusy)
        let snapshot = await warmer.snapshot()
        XCTAssertEqual(snapshot.count(for: .deniedBusy), 1)
    }

    func testMetricsAreMachineReadableBoundedAndExcludeIdentifiersURLsAndErrors() async throws {
        let secretID: FeedItemID = "user-123-secret"
        let secretURL = URL(string: "https://example.com/private.m3u8?token=secret")!
        let item = FeedPlaybackItem(
            id: secretID,
            source: .stream(url: secretURL, kind: .videoOnDemand),
            estimatedPreparationBytes: 100
        )
        let backend = BackgroundPreparingFake(failingItemIDs: [secretID])
        let warmer = try HLSFeedBackgroundWarmer(policy: makePolicy(), backend: backend)

        let result = await warmer.warm(makeRequest(items: [item]))
        let data = try await warmer.machineReadableSummary()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(
            HLSFeedBackgroundWarmingSnapshot.self,
            from: data
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(decoded.count(for: .failed), 1)
        XCTAssertEqual(
            decoded.outcomes.count,
            HLSFeedBackgroundWarmingSnapshot.Outcome.allCases.count
        )
        XCTAssertEqual(decoded.maximumOutcomeCardinality, decoded.outcomes.count)
        XCTAssertFalse(text.contains(secretID.rawValue))
        XCTAssertFalse(text.contains(secretURL.absoluteString))
        XCTAssertFalse(text.contains("backend-secret-error"))
    }

    private func makePolicy(
        maximumItemCount: Int = 2,
        maximumLeadingSegmentsPerItem: Int = 1,
        maximumEstimatedByteCount: Int = 1_024,
        maximumConcurrentPreparations: Int = 1,
        maximumExecutionTime: Duration = .seconds(30),
        minimumRemainingCacheValidity: Duration = .seconds(30),
        allowsCellularAccess: Bool = false,
        allowsConstrainedNetworkAccess: Bool = false,
        allowsExpensiveNetworkAccess: Bool = false,
        allowsLowPowerMode: Bool = false
    ) -> HLSFeedBackgroundWarmingPolicy {
        HLSFeedBackgroundWarmingPolicy(
            maximumItemCount: maximumItemCount,
            maximumLeadingSegmentsPerItem: maximumLeadingSegmentsPerItem,
            maximumEstimatedByteCount: maximumEstimatedByteCount,
            maximumConcurrentPreparations: maximumConcurrentPreparations,
            maximumExecutionTime: maximumExecutionTime,
            minimumRemainingCacheValidity: minimumRemainingCacheValidity,
            allowsCellularAccess: allowsCellularAccess,
            allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess,
            allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess,
            allowsLowPowerMode: allowsLowPowerMode
        )
    }

    private func makeItems(
        count: Int,
        estimatedBytes: Int = 100
    ) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "background-\(index)"),
                source: .stream(
                    url: URL(string: "https://example.com/background-\(index).m3u8")!,
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: estimatedBytes
            )
        }
    }

    private func makeRequest(
        items: [FeedPlaybackItem],
        environment: HLSFeedBackgroundEnvironment = .init(networkInterface: .wifi),
        availableExecutionTime: Duration = .seconds(30)
    ) -> HLSFeedBackgroundWarmingRequest {
        HLSFeedBackgroundWarmingRequest(
            candidates: items.map { .init(item: $0) },
            environment: environment,
            availableExecutionTime: availableExecutionTime
        )
    }
}

private actor BackgroundPreparingFake: FeedPreparing {
    struct Audit: Sendable {
        let requests: [FeedPreparationRequest]
        let maximumActiveCount: Int
        let cancellationCount: Int
        let completedCount: Int
    }

    struct Failure: Error, Sendable {
        let message = "backend-secret-error"
    }

    let delay: Duration
    let delaysByItemID: [FeedItemID: Duration]
    let failingItemIDs: Set<FeedItemID>
    private var requests: [FeedPreparationRequest] = []
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var cancellationCount = 0
    private var completedCount = 0

    init(
        delay: Duration = .zero,
        delaysByItemID: [FeedItemID: Duration] = [:],
        failingItemIDs: Set<FeedItemID> = []
    ) {
        self.delay = delay
        self.delaysByItemID = delaysByItemID
        self.failingItemIDs = failingItemIDs
    }

    func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem {
        requests.append(request)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        do {
            let itemDelay = delaysByItemID[request.item.id] ?? delay
            if itemDelay > .zero { try await ContinuousClock().sleep(for: itemDelay) }
            try Task.checkCancellation()
        } catch {
            cancellationCount += 1
            throw error
        }
        if failingItemIDs.contains(request.item.id) { throw Failure() }
        completedCount += 1
        let byteCount = request.item.estimatedPreparationBytes
        return FeedPreparedItem(
            itemID: request.item.id,
            generation: request.generation,
            manifestURLs: [],
            mediaPlaylistCount: 1,
            leadingSegmentCount: request.maximumLeadingSegments,
            preparedResourceCount: request.maximumLeadingSegments,
            preparedByteCount: byteCount,
            cacheHitCount: 1,
            originFetchCount: 1,
            cacheHitByteCount: byteCount / 2,
            originFetchByteCount: byteCount - (byteCount / 2)
        )
    }

    func audit() -> Audit {
        Audit(
            requests: requests,
            maximumActiveCount: maximumActiveCount,
            cancellationCount: cancellationCount,
            completedCount: completedCount
        )
    }
}
