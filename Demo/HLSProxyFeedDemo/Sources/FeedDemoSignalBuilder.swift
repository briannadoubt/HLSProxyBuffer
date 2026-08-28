import CoreGraphics
import Foundation
import ProxyPlayerKit

struct FeedDemoScrollGeometrySample: Equatable, Sendable {
    static let samplesPerPage: Double = 60

    let pageOffset: Double
    let viewportSize: CGSize

    init(contentOffsetY: CGFloat, viewportSize: CGSize) {
        self.viewportSize = viewportSize
        guard viewportSize.height > 0 else {
            pageOffset = 0
            return
        }
        let rawPageOffset = Double(contentOffsetY / viewportSize.height)
        pageOffset = (rawPageOffset * Self.samplesPerPage).rounded()
            / Self.samplesPerPage
    }
}

enum FeedDemoScrollGeometryProjector {
    static func frames(
        itemIDs: [FeedItemID],
        focusedItemID: FeedItemID?,
        sample: FeedDemoScrollGeometrySample,
        itemsBehind: Int,
        itemsAhead: Int
    ) -> [FeedItemID: CGRect] {
        guard sample.viewportSize.height > 0, !itemIDs.isEmpty else { return [:] }
        let nearestIndex = min(
            itemIDs.count - 1,
            max(0, Int(sample.pageOffset.rounded()))
        )
        let lowerIndex = max(0, nearestIndex - itemsBehind - 1)
        let upperIndex = min(itemIDs.count - 1, nearestIndex + itemsAhead + 1)
        var indexes = Set(lowerIndex...upperIndex)
        if let focusedItemID,
           let focusedIndex = itemIDs.firstIndex(of: focusedItemID) {
            indexes.insert(focusedIndex)
        }

        let height = sample.viewportSize.height
        return Dictionary(uniqueKeysWithValues: indexes.map { index in
            let originY = (CGFloat(index) - CGFloat(sample.pageOffset)) * height
            return (
                itemIDs[index],
                CGRect(
                    x: 0,
                    y: originY,
                    width: sample.viewportSize.width,
                    height: height
                )
            )
        })
    }
}

struct FeedDemoSignalBuilder {
    private(set) var orderedItemIDs: [FeedItemID]
    private(set) var focusedItemID: FeedItemID?
    private(set) var predictedDestinationIDs: [FeedItemID] = []
    private(set) var generation = FeedNavigationGeneration(rawValue: 0)
    private var lastAnchor: (itemID: FeedItemID, distance: Double, observedAt: Duration)?

    init(orderedItemIDs: [FeedItemID]) {
        self.orderedItemIDs = orderedItemIDs
    }

    mutating func makeSignal(
        frames: [FeedItemID: CGRect],
        viewport: CGRect,
        observedAt: Duration,
        requestedFocus: FeedItemID? = nil
    ) -> FeedViewportSignal? {
        guard viewport.height > 0 else { return nil }
        let visible = orderedItemIDs.compactMap { itemID -> FeedItemVisibility? in
            guard let frame = frames[itemID], frame.height > 0 else { return nil }
            let intersection = frame.intersection(viewport)
            let visibleHeight = intersection.isNull ? 0 : max(0, intersection.height)
            let fraction = min(1, visibleHeight / frame.height)
            guard fraction > 0 else { return nil }
            return FeedItemVisibility(
                itemID: itemID,
                fraction: fraction,
                distanceInViewports: (frame.midY - viewport.midY) / viewport.height
            )
        }
        guard !visible.isEmpty else { return nil }

        let nextFocus = requestedFocus.flatMap { requested in
            orderedItemIDs.contains(requested) ? requested : nil
        } ?? visible.sorted(by: isBetterFocus).first?.itemID
        guard let nextFocus else { return nil }
        if nextFocus != focusedItemID {
            generation = FeedNavigationGeneration(rawValue: generation.rawValue &+ 1)
            focusedItemID = nextFocus
        }

        let focusedDistance = visible.first(where: { $0.itemID == nextFocus })?.distanceInViewports ?? 0
        let velocity = measuredVelocity(
            itemID: nextFocus,
            distance: focusedDistance,
            observedAt: observedAt,
            frames: frames,
            viewport: viewport
        )
        lastAnchor = (nextFocus, focusedDistance, observedAt)

        let destinations = predictions(
            focusedItemID: nextFocus,
            velocity: velocity,
            visible: visible
        )
        predictedDestinationIDs = destinations.map(\.itemID)
        return FeedViewportSignal(
            generation: generation,
            focusedItemID: nextFocus,
            visibleItems: visible,
            velocityInViewportsPerSecond: velocity,
            predictedDestinations: destinations,
            observedAt: observedAt
        )
    }

    private func isBetterFocus(_ lhs: FeedItemVisibility, _ rhs: FeedItemVisibility) -> Bool {
        if lhs.fraction != rhs.fraction { return lhs.fraction > rhs.fraction }
        let lhsDistance = abs(lhs.distanceInViewports)
        let rhsDistance = abs(rhs.distanceInViewports)
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        return index(of: lhs.itemID) < index(of: rhs.itemID)
    }

    private func measuredVelocity(
        itemID: FeedItemID,
        distance: Double,
        observedAt: Duration,
        frames: [FeedItemID: CGRect],
        viewport: CGRect
    ) -> Double {
        guard let lastAnchor else { return 0 }
        let elapsed = (observedAt - lastAnchor.observedAt).seconds
        guard elapsed > 0.001 else { return 0 }
        let currentDistance: Double
        if let sameFrame = frames[lastAnchor.itemID] {
            currentDistance = (sameFrame.midY - viewport.midY) / viewport.height
        } else if lastAnchor.itemID == itemID {
            currentDistance = distance
        } else {
            return 0
        }
        return min(20, max(-20, -(currentDistance - lastAnchor.distance) / elapsed))
    }

    private func predictions(
        focusedItemID: FeedItemID,
        velocity: Double,
        visible: [FeedItemVisibility]
    ) -> [FeedDestinationPrediction] {
        let focusedIndex = index(of: focusedItemID)
        guard focusedIndex != Int.max else { return [] }
        let direction: Int
        if abs(velocity) >= 0.15 {
            direction = velocity > 0 ? 1 : -1
        } else if let nearest = visible
            .filter({ $0.itemID != focusedItemID })
            .min(by: { abs($0.distanceInViewports) < abs($1.distanceInViewports) }) {
            direction = index(of: nearest.itemID) > focusedIndex ? 1 : -1
        } else {
            direction = 1
        }
        return (1...2).compactMap { offset in
            let candidateIndex = focusedIndex + direction * offset
            guard orderedItemIDs.indices.contains(candidateIndex) else { return nil }
            return FeedDestinationPrediction(
                itemID: orderedItemIDs[candidateIndex],
                confidence: offset == 1 ? 0.9 : 0.6
            )
        }
    }

    private func index(of itemID: FeedItemID) -> Int {
        orderedItemIDs.firstIndex(of: itemID) ?? Int.max
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
