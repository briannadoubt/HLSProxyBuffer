import Foundation
@testable import ProxyPlayerKit

struct FeedNavigationTrace: Codable, Equatable, Sendable {
    enum Pattern: String, Codable, CaseIterable, Sendable {
        case pagedSwipes
        case rapidFocusReversals
        case continuousWindowedScrolling
        case longFormSelection
        case liveWindows
        case offlineRevisits
        case compatibleStitchedClips
    }

    struct Visibility: Codable, Equatable, Sendable {
        let itemIndex: Int
        let fraction: Double
        let distanceInViewports: Double
    }

    struct Prediction: Codable, Equatable, Sendable {
        let itemIndex: Int
        let confidence: Double
    }

    struct Step: Codable, Equatable, Sendable {
        let focusedItemIndex: Int
        let visibleItems: [Visibility]
        let velocityInViewportsPerSecond: Double
        let predictedDestinations: [Prediction]
        let elapsedMilliseconds: Int
    }

    let name: String
    let pattern: Pattern
    let steps: [Step]

    func signals(for items: [FeedPlaybackItem]) throws -> [FeedViewportSignal] {
        try steps.enumerated().map { offset, step in
            func itemID(at index: Int, role: String) throws -> FeedItemID {
                guard items.indices.contains(index) else {
                    throw FeedTraceError(
                        traceName: name,
                        stepIndex: offset,
                        issue: "\(role) index \(index) is outside 0..<\(items.count)"
                    )
                }
                return items[index].id
            }

            let focusedItemID = try itemID(at: step.focusedItemIndex, role: "focused item")
            let visibleItems = try step.visibleItems.map { visibility in
                FeedItemVisibility(
                    itemID: try itemID(at: visibility.itemIndex, role: "visible item"),
                    fraction: visibility.fraction,
                    distanceInViewports: visibility.distanceInViewports
                )
            }
            let predictions = try step.predictedDestinations.map { prediction in
                FeedDestinationPrediction(
                    itemID: try itemID(at: prediction.itemIndex, role: "predicted item"),
                    confidence: prediction.confidence
                )
            }
            return FeedViewportSignal(
                generation: .init(rawValue: UInt64(offset + 1)),
                focusedItemID: focusedItemID,
                visibleItems: visibleItems,
                velocityInViewportsPerSecond: step.velocityInViewportsPerSecond,
                predictedDestinations: predictions,
                observedAt: .milliseconds(step.elapsedMilliseconds)
            )
        }
    }

    static func standardCatalog(
        itemCount: Int,
        stepsPerTrace: Int = 76
    ) -> [FeedNavigationTrace] {
        precondition(itemCount >= 4)
        precondition(stepsPerTrace >= 2)

        return Pattern.allCases.map { pattern in
            FeedNavigationTrace(
                name: pattern.rawValue,
                pattern: pattern,
                steps: (0..<stepsPerTrace).map { step in
                    makeStep(pattern: pattern, step: step, itemCount: itemCount)
                }
            )
        }
    }
}

struct FeedTraceError: Error, Codable, Equatable, CustomStringConvertible, Sendable {
    let traceName: String
    let stepIndex: Int
    let issue: String

    var description: String {
        "Trace '\(traceName)' failed at step \(stepIndex): \(issue)"
    }

    func artifact() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct FeedTraceReplayReport: Codable, Equatable, Sendable {
    enum CacheMode: String, Codable, Sendable {
        case cold
        case warm
    }

    let traceName: String
    let pattern: FeedNavigationTrace.Pattern
    let cacheMode: CacheMode
    let stepCount: Int
    let focusChangeCount: Int
    let planFingerprints: [String]
    let preparedItemIDs: [String]
    let cacheHits: Int
    let cacheMisses: Int
    let cancellationCount: Int
    let maximumResidentItems: Int
    let maximumEstimatedPreparationBytes: Int

    func artifact() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct FeedTraceReplayResult: Equatable, Sendable {
    let report: FeedTraceReplayReport
    let warmedItemIDs: Set<FeedItemID>
}

struct FeedTraceReplayer: Sendable {
    let planner: FeedPlanner

    init(planner: FeedPlanner) {
        self.planner = planner
    }

    func replay(
        _ trace: FeedNavigationTrace,
        items: [FeedPlaybackItem],
        initiallyCachedItemIDs: Set<FeedItemID> = []
    ) throws -> FeedTraceReplayResult {
        let signals = try trace.signals(for: items)
        var previousPlan: FeedPlan?
        var cachedItemIDs = initiallyCachedItemIDs
        var preparedItemIDs: [String] = []
        var fingerprints: [String] = []
        var cacheHits = 0
        var cacheMisses = 0
        var cancellationCount = 0
        var maximumResidentItems = 0
        var maximumEstimatedPreparationBytes = 0

        for (stepIndex, signal) in signals.enumerated() {
            let plan: FeedPlan
            do {
                plan = try planner.makePlan(
                    items: items,
                    signal: signal,
                    previousPlan: previousPlan
                )
            } catch {
                throw FeedTraceError(
                    traceName: trace.name,
                    stepIndex: stepIndex,
                    issue: "planner rejected the signal: \(error.localizedDescription)"
                )
            }
            maximumResidentItems = max(maximumResidentItems, plan.desiredEntries.count)
            maximumEstimatedPreparationBytes = max(
                maximumEstimatedPreparationBytes,
                plan.estimatedPreparationBytes
            )
            cancellationCount += plan.cancellations.count

            for preparation in plan.preparations {
                preparedItemIDs.append(preparation.itemID.rawValue)
                if cachedItemIDs.contains(preparation.itemID) {
                    cacheHits += 1
                } else {
                    cacheMisses += 1
                    cachedItemIDs.insert(preparation.itemID)
                }
            }
            fingerprints.append(Self.fingerprint(plan))
            previousPlan = plan
        }

        let focusChangeCount = zip(signals, signals.dropFirst()).reduce(into: 0) { count, pair in
            if pair.0.focusedItemID != pair.1.focusedItemID {
                count += 1
            }
        }
        let report = FeedTraceReplayReport(
            traceName: trace.name,
            pattern: trace.pattern,
            cacheMode: initiallyCachedItemIDs.isEmpty ? .cold : .warm,
            stepCount: signals.count,
            focusChangeCount: focusChangeCount,
            planFingerprints: fingerprints,
            preparedItemIDs: preparedItemIDs,
            cacheHits: cacheHits,
            cacheMisses: cacheMisses,
            cancellationCount: cancellationCount,
            maximumResidentItems: maximumResidentItems,
            maximumEstimatedPreparationBytes: maximumEstimatedPreparationBytes
        )
        return FeedTraceReplayResult(report: report, warmedItemIDs: cachedItemIDs)
    }

    private static func fingerprint(_ plan: FeedPlan) -> String {
        let disposition = switch plan.disposition {
        case .accepted: "accepted"
        case .ignoredStaleSignal: "ignored-stale-signal"
        }
        let entries = plan.desiredEntries.map {
            "\($0.itemID.rawValue):\($0.role.rawValue):\($0.estimatedPreparationBytes)"
        }.joined(separator: ",")
        let cancellations = plan.cancellations.map(\.itemID.rawValue).joined(separator: ",")
        return "g=\(plan.generation.rawValue)|d=\(disposition)|e=\(entries)|c=\(cancellations)"
    }
}

private extension FeedNavigationTrace {
    static func makeStep(pattern: Pattern, step: Int, itemCount: Int) -> Step {
        let focus: Int
        let velocity: Double
        let visible: [Visibility]
        let predictions: [Prediction]

        switch pattern {
        case .pagedSwipes:
            focus = step % itemCount
            velocity = 5
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            predictions = [.init(itemIndex: (focus + 1) % itemCount, confidence: 0.92)]
        case .rapidFocusReversals:
            let period = max(2, (itemCount - 1) * 2)
            let position = step % period
            focus = position < itemCount ? position : period - position
            velocity = position < itemCount ? 9 : -9
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            let destination = min(itemCount - 1, max(0, focus + (velocity > 0 ? 1 : -1)))
            predictions = [.init(itemIndex: destination, confidence: 0.78)]
        case .continuousWindowedScrolling:
            focus = (step * 2 + (step / itemCount)) % itemCount
            velocity = step.isMultiple(of: 2) ? 3.5 : -2.5
            visible = windowVisibility(focus: focus, itemCount: itemCount)
            predictions = [.init(itemIndex: (focus + 2) % itemCount, confidence: 0.64)]
        case .longFormSelection:
            focus = (step * 3 + 1) % itemCount
            velocity = 0.4
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            predictions = []
        case .liveWindows:
            focus = (step * 5 + 2) % itemCount
            velocity = 1.2
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            predictions = [.init(itemIndex: (focus + 1) % itemCount, confidence: 0.7)]
        case .offlineRevisits:
            let revisit = [0, 1, 2, 0, 3, 1]
            focus = revisit[step % revisit.count] % itemCount
            velocity = step.isMultiple(of: 3) ? -4 : 4
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            predictions = []
        case .compatibleStitchedClips:
            focus = (step * 7 + 3) % itemCount
            velocity = 2
            visible = pageVisibility(focus: focus, itemCount: itemCount)
            predictions = [.init(itemIndex: (focus + 1) % itemCount, confidence: 0.85)]
        }

        return Step(
            focusedItemIndex: focus,
            visibleItems: visible,
            velocityInViewportsPerSecond: velocity,
            predictedDestinations: predictions,
            elapsedMilliseconds: step * 16
        )
    }

    static func pageVisibility(focus: Int, itemCount: Int) -> [Visibility] {
        let neighbor = (focus + 1) % itemCount
        return [
            .init(itemIndex: focus, fraction: 1, distanceInViewports: 0),
            .init(itemIndex: neighbor, fraction: 0.08, distanceInViewports: 0.92),
        ]
    }

    static func windowVisibility(focus: Int, itemCount: Int) -> [Visibility] {
        [
            .init(itemIndex: (focus + itemCount - 1) % itemCount, fraction: 0.32, distanceInViewports: -0.7),
            .init(itemIndex: focus, fraction: 0.9, distanceInViewports: 0),
            .init(itemIndex: (focus + 1) % itemCount, fraction: 0.42, distanceInViewports: 0.6),
        ]
    }
}
