import XCTest
@testable import ProxyPlayerKit

final class FeedPlannerTests: XCTestCase {
    func testPagedSignalPrioritizesFocusVisibilityAndPrediction() throws {
        let items = makeItems(count: 6)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 3,
            maximumPrefetchItems: 2,
            maximumConcurrentPreparations: 3,
            maximumEstimatedPreparationBytes: 3 * megabyte,
            neighborPredictionHorizon: 2
        ))
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 1),
            focusedItemID: items[2].id,
            visibleItems: [
                .init(itemID: items[1].id, fraction: 0.35, distanceInViewports: -0.8),
                .init(itemID: items[2].id, fraction: 1, distanceInViewports: 0),
            ],
            velocityInViewportsPerSecond: 5,
            predictedDestinations: [
                .init(itemID: items[4].id, confidence: 0.95)
            ],
            observedAt: .seconds(1)
        )

        let plan = try planner.makePlan(items: items, signal: signal)

        XCTAssertEqual(plan.disposition, .accepted)
        XCTAssertEqual(plan.desiredEntries.map(\.itemID), [items[2].id, items[1].id, items[4].id])
        XCTAssertEqual(plan.desiredEntries.map(\.role), [.focused, .visible, .predicted])
        XCTAssertEqual(plan.preparations.count, 3)
        XCTAssertLessThanOrEqual(plan.estimatedPreparationBytes, 3 * megabyte)
    }

    func testContinuousSignalRanksNeighborsInVelocityDirection() throws {
        let items = makeItems(count: 7)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 4,
            maximumPrefetchItems: 3,
            maximumConcurrentPreparations: 4,
            maximumEstimatedPreparationBytes: 4 * megabyte,
            neighborPredictionHorizon: 3
        ))
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 8),
            focusedItemID: items[2].id,
            visibleItems: [
                .init(itemID: items[2].id, fraction: 0.8, distanceInViewports: 0.1)
            ],
            velocityInViewportsPerSecond: 3.5,
            observedAt: .seconds(4)
        )

        let plan = try planner.makePlan(items: items, signal: signal)

        XCTAssertEqual(plan.desiredEntries.map(\.itemID), [
            items[2].id,
            items[3].id,
            items[4].id,
            items[5].id,
        ])
        XCTAssertEqual(plan.desiredEntries.dropFirst().map(\.role), [
            .neighbor,
            .neighbor,
            .neighbor,
        ])
    }

    func testAtomicTargetHonorsByteBudgetWhilePreparationsHonorConcurrency() throws {
        let items = makeItems(count: 5, estimatedPreparationBytes: megabyte)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 4,
            maximumPrefetchItems: 3,
            maximumConcurrentPreparations: 1,
            maximumEstimatedPreparationBytes: 2 * megabyte,
            neighborPredictionHorizon: 3
        ))
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 1),
            focusedItemID: items[0].id,
            visibleItems: [.init(itemID: items[0].id, fraction: 1, distanceInViewports: 0)],
            velocityInViewportsPerSecond: 2,
            observedAt: .zero
        )

        let firstPlan = try planner.makePlan(items: items, signal: signal)
        let secondPlan = try planner.makePlan(
            items: items,
            signal: signal,
            previousPlan: firstPlan
        )

        XCTAssertEqual(firstPlan.desiredEntries.count, 2)
        XCTAssertEqual(firstPlan.preparations.count, 1)
        XCTAssertEqual(secondPlan.desiredEntries.count, 2)
        XCTAssertTrue(secondPlan.preparations.isEmpty)
        XCTAssertLessThanOrEqual(secondPlan.estimatedPreparationBytes, 2 * megabyte)
    }

    func testStationaryWorkingSetContainsCurrentPlusTwoInEachDirection() throws {
        let items = makeItems(count: 9)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 5,
            maximumEstimatedPreparationBytes: 5 * megabyte,
            neighborPredictionHorizon: 2,
            maximumAheadItems: 2,
            maximumBehindItems: 2
        ))
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 1),
            focusedItemID: items[4].id,
            visibleItems: [.init(itemID: items[4].id, fraction: 1, distanceInViewports: 0)],
            observedAt: .zero
        )

        let plan = try planner.makePlan(items: items, signal: signal)

        XCTAssertEqual(plan.desiredEntries.map(\.itemID), [
            items[4].id,
            items[5].id,
            items[3].id,
            items[6].id,
            items[2].id,
        ])
        XCTAssertEqual(plan.desiredItemIDs, Set(items[2...6].map(\.id)))
    }

    func testWorkingSetClampsAtCollectionEdges() throws {
        let items = makeItems(count: 5)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 5,
            maximumEstimatedPreparationBytes: 5 * megabyte,
            neighborPredictionHorizon: 2,
            maximumAheadItems: 2,
            maximumBehindItems: 2
        ))

        let first = try planner.makePlan(
            items: items,
            signal: makeStationarySignal(generation: 1, focused: items[0].id)
        )
        let last = try planner.makePlan(
            items: items,
            signal: makeStationarySignal(generation: 2, focused: items[4].id)
        )

        XCTAssertEqual(first.desiredItemIDs, Set(items[0...2].map(\.id)))
        XCTAssertEqual(last.desiredItemIDs, Set(items[2...4].map(\.id)))
    }

    func testWorkingSetSafelyClampsExtremeDirectLimits() throws {
        let items = makeItems(count: 3)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 3,
            maximumPrefetchItems: .max,
            maximumConcurrentPreparations: 3,
            maximumEstimatedPreparationBytes: 3 * megabyte,
            neighborPredictionHorizon: 0,
            maximumAheadItems: .max,
            maximumBehindItems: .max
        ))

        let plan = try planner.makePlan(
            items: items,
            signal: makeStationarySignal(generation: 1, focused: items[1].id)
        )

        XCTAssertEqual(plan.desiredItemIDs, Set(items.map(\.id)))
    }

    func testFastVelocityExhaustsDirectionBeforeOppositeSide() throws {
        let items = makeItems(count: 9)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 5,
            maximumEstimatedPreparationBytes: 5 * megabyte,
            neighborPredictionHorizon: 2,
            maximumAheadItems: 2,
            maximumBehindItems: 2,
            directionalVelocityThreshold: 0.5,
            fastVelocityThreshold: 3
        ))

        let forward = try planner.makePlan(
            items: items,
            signal: makeSignal(
                generation: 1,
                focused: items[4].id,
                velocity: 6,
                observedAt: .zero
            )
        )
        let backward = try planner.makePlan(
            items: items,
            signal: makeSignal(
                generation: 2,
                focused: items[4].id,
                velocity: -6,
                observedAt: .zero
            )
        )

        XCTAssertEqual(forward.desiredEntries.map(\.itemID), [
            items[4].id, items[5].id, items[6].id, items[3].id, items[2].id,
        ])
        XCTAssertEqual(backward.desiredEntries.map(\.itemID), [
            items[4].id, items[3].id, items[2].id, items[5].id, items[6].id,
        ])
    }

    func testPredictionsAreDeduplicatedAndCannotEscapeWorkingSet() throws {
        let items = makeItems(count: 10)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 5,
            maximumEstimatedPreparationBytes: 5 * megabyte,
            neighborPredictionHorizon: 2,
            maximumAheadItems: 2,
            maximumBehindItems: 2
        ))
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 1),
            focusedItemID: items[4].id,
            visibleItems: [.init(itemID: items[4].id, fraction: 1, distanceInViewports: 0)],
            velocityInViewportsPerSecond: 5,
            predictedDestinations: [
                .init(itemID: items[6].id, confidence: 0.9),
                .init(itemID: items[6].id, confidence: 0.8),
                .init(itemID: items[9].id, confidence: 1),
            ],
            observedAt: .zero
        )

        let plan = try planner.makePlan(items: items, signal: signal)

        XCTAssertEqual(plan.desiredEntries.filter { $0.itemID == items[6].id }.count, 1)
        XCTAssertFalse(plan.desiredItemIDs.contains(items[9].id))
        XCTAssertEqual(plan.desiredItemIDs, Set(items[2...6].map(\.id)))
    }

    func testAsymmetricBoundsAndReversalReplaceTargetAtomically() throws {
        let items = makeItems(count: 12)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 2,
            maximumEstimatedPreparationBytes: 5 * megabyte,
            neighborPredictionHorizon: 3,
            maximumAheadItems: 3,
            maximumBehindItems: 1
        ))
        let forward = try planner.makePlan(
            items: items,
            signal: makeSignal(
                generation: 1,
                focused: items[3].id,
                velocity: 8,
                observedAt: .seconds(1)
            )
        )
        let reversed = try planner.makePlan(
            items: items,
            signal: makeSignal(
                generation: 2,
                focused: items[7].id,
                velocity: -8,
                observedAt: .seconds(2)
            ),
            previousPlan: forward
        )

        XCTAssertEqual(forward.desiredItemIDs, Set(items[2...6].map(\.id)))
        XCTAssertEqual(reversed.desiredItemIDs, Set(items[6...10].map(\.id)))
        XCTAssertEqual(Set(reversed.cancellations.map(\.itemID)), Set(items[2...5].map(\.id)))
        XCTAssertLessThanOrEqual(reversed.preparations.count, 2)
    }

    func testStaleGenerationSchedulesNoWorkAndPreservesCurrentPlan() throws {
        let items = makeItems(count: 5)
        let planner = FeedPlanner()
        let current = try planner.makePlan(
            items: items,
            signal: makeSignal(generation: 5, focused: items[3].id, observedAt: .seconds(5))
        )

        let stale = try planner.makePlan(
            items: items,
            signal: makeSignal(generation: 4, focused: items[0].id, observedAt: .seconds(6)),
            previousPlan: current
        )

        XCTAssertEqual(stale.disposition, .ignoredStaleSignal)
        XCTAssertEqual(stale.generation, current.generation)
        XCTAssertEqual(stale.desiredEntries, current.desiredEntries)
        XCTAssertTrue(stale.preparations.isEmpty)
        XCTAssertTrue(stale.cancellations.isEmpty)
    }

    func testFocusChangeRequestsCancellationWithinOneHundredMilliseconds() throws {
        let items = makeItems(count: 6)
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 3,
            maximumPrefetchItems: 2,
            maximumConcurrentPreparations: 3,
            maximumEstimatedPreparationBytes: 3 * megabyte,
            neighborPredictionHorizon: 2,
            cancellationDeadline: .milliseconds(100)
        ))
        let first = try planner.makePlan(
            items: items,
            signal: makeSignal(generation: 1, focused: items[0].id, observedAt: .seconds(1))
        )
        let observedAt = Duration.seconds(2)

        let replacement = try planner.makePlan(
            items: items,
            signal: makeSignal(generation: 2, focused: items[5].id, observedAt: observedAt),
            previousPlan: first
        )

        XCTAssertFalse(replacement.cancellations.isEmpty)
        XCTAssertTrue(replacement.cancellations.allSatisfy { cancellation in
            cancellation.requestedAt == observedAt
                && cancellation.deadline - cancellation.requestedAt == .milliseconds(100)
        })
        XCTAssertTrue(Set(replacement.cancellations.map(\.itemID)).isSubset(of: first.desiredItemIDs))
    }

    func testFocusedItemCannotSilentlyExceedByteBudget() {
        let item = makeItems(count: 1, estimatedPreparationBytes: 2 * megabyte)[0]
        let planner = FeedPlanner(limits: .init(
            maximumEstimatedPreparationBytes: megabyte
        ))

        XCTAssertThrowsError(try planner.makePlan(
            items: [item],
            signal: makeSignal(generation: 1, focused: item.id, observedAt: .zero)
        )) { error in
            XCTAssertEqual(
                error as? FeedPlanningError,
                .focusedItemExceedsByteBudget(
                    itemID: item.id,
                    required: 2 * self.megabyte,
                    limit: self.megabyte
                )
            )
        }
    }

    func testClipSequenceIsAFirstClassSourceAndMustNotBeEmpty() throws {
        let valid = FeedPlaybackItem(
            id: "stitched",
            source: .clips([
                URL(fileURLWithPath: "/fixtures/intro.m3u8"),
                URL(fileURLWithPath: "/fixtures/main.m3u8"),
            ]),
            estimatedPreparationBytes: megabyte
        )
        let invalid = FeedPlaybackItem(
            id: "empty",
            source: .clips([]),
            estimatedPreparationBytes: 0
        )
        let invalidTyped = FeedPlaybackItem(
            id: "empty-typed",
            source: .compatibleClips([]),
            estimatedPreparationBytes: 0
        )
        let planner = FeedPlanner()

        _ = try planner.makePlan(
            items: [valid],
            signal: makeSignal(generation: 1, focused: valid.id, observedAt: .zero)
        )
        XCTAssertThrowsError(try planner.makePlan(
            items: [invalid],
            signal: makeSignal(generation: 2, focused: invalid.id, observedAt: .zero)
        )) { error in
            XCTAssertEqual(error as? FeedPlanningError, .emptyClipSequence(invalid.id))
        }
        XCTAssertThrowsError(try planner.makePlan(
            items: [invalidTyped],
            signal: makeSignal(generation: 3, focused: invalidTyped.id, observedAt: .zero)
        )) { error in
            XCTAssertEqual(error as? FeedPlanningError, .emptyClipSequence(invalidTyped.id))
        }
    }

    func testEmptyAndDuplicateStableIDsAreRejected() {
        let empty = FeedPlaybackItem(
            id: .init(rawValue: "   "),
            source: .stream(
                url: URL(fileURLWithPath: "/fixtures/empty-id.m3u8"),
                kind: .videoOnDemand
            ),
            estimatedPreparationBytes: megabyte
        )
        let duplicateItems = makeItems(count: 1) + makeItems(count: 1)
        let planner = FeedPlanner()

        XCTAssertThrowsError(try planner.makePlan(
            items: [empty],
            signal: FeedViewportSignal(
                generation: .init(rawValue: 1),
                focusedItemID: nil,
                visibleItems: [],
                observedAt: .zero
            )
        )) { error in
            XCTAssertEqual(error as? FeedPlanningError, .emptyItemID)
        }
        XCTAssertThrowsError(try planner.makePlan(
            items: duplicateItems,
            signal: makeSignal(
                generation: 2,
                focused: duplicateItems[0].id,
                observedAt: .zero
            )
        )) { error in
            XCTAssertEqual(error as? FeedPlanningError, .duplicateItemID(duplicateItems[0].id))
        }
    }

    func testContractValuesAreSendable() {
        assertSendable(FeedItemID(rawValue: "id"))
        assertSendable(makeItems(count: 1)[0])
        assertSendable(makeSignal(generation: 1, focused: "item-0", observedAt: .zero))
        assertSendable(FeedPlanningLimits())
        assertSendable(FeedPlanner())
    }
}

private extension FeedPlannerTests {
    var megabyte: Int { 1_024 * 1_024 }

    func makeItems(
        count: Int,
        estimatedPreparationBytes: Int? = nil
    ) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "item-\(index)"),
                source: .stream(
                    url: URL(fileURLWithPath: "/fixtures/item-\(index).m3u8"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: estimatedPreparationBytes ?? megabyte
            )
        }
    }

    func makeSignal(
        generation: UInt64,
        focused: FeedItemID,
        velocity: Double = 2,
        observedAt: Duration
    ) -> FeedViewportSignal {
        FeedViewportSignal(
            generation: .init(rawValue: generation),
            focusedItemID: focused,
            visibleItems: [
                .init(itemID: focused, fraction: 1, distanceInViewports: 0)
            ],
            velocityInViewportsPerSecond: velocity,
            observedAt: observedAt
        )
    }

    func makeStationarySignal(
        generation: UInt64,
        focused: FeedItemID
    ) -> FeedViewportSignal {
        makeSignal(
            generation: generation,
            focused: focused,
            velocity: 0,
            observedAt: .zero
        )
    }

    func assertSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}
