import Foundation
import HLSCore
import LocalProxy
import ProxyPlayerKit

private struct BenchmarkResult {
    let name: String
    let iterations: Int
    let duration: Duration

    var operationsPerSecond: Double {
        Double(iterations) / duration.seconds
    }
}

private extension Duration {
    var seconds: Double {
        let values = components
        return Double(values.seconds) + Double(values.attoseconds) / 1e18
    }
}

private actor UnusedSegmentSource: SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        throw URLError(.resourceUnavailable)
    }
}

@main
private enum HLSProxyBenchmarks {
    private static let clock = ContinuousClock()
    private static let segmentCount = 128
    private static let iterations = 1_000_000

    static func main() async {
        runFeedPlannerBenchmark()

        let segments = (0..<segmentCount).map { sequence in
            HLSSegment(
                url: URL(string: "https://benchmark.invalid/\(sequence).m4s")!,
                duration: 2,
                sequence: sequence
            )
        }
        let playlist = MediaPlaylist(
            targetDuration: 2,
            mediaSequence: 0,
            segments: segments
        )
        let keys = segments.map { SegmentIdentity.key(for: $0) }
        let payload = Data(repeating: 0x5a, count: 64 * 1024)

        let cache = HLSSegmentCache(capacityBytes: payload.count * segmentCount)
        let catalog = SegmentCatalog()
        await catalog.update(with: playlist)
        for key in keys {
            await cache.put(payload, for: key)
        }

        let results = [
            await benchmark(name: "memory-cache-hit", iterations: iterations) { index in
                _ = await cache.get(keys[index % keys.count])
            },
            await concurrentBenchmark(name: "concurrent-memory-cache-hit", iterations: iterations) { index in
                _ = await cache.get(keys[index % keys.count])
            },
            await benchmark(name: "catalog-lookup", iterations: iterations) { index in
                _ = await catalog.segmentEntry(forKey: keys[index % keys.count])
            },
            await cachedRequestBenchmark(
                cache: cache,
                catalog: catalog,
                keys: keys,
                iterations: iterations,
                isConcurrent: false
            ),
            await cachedRequestBenchmark(
                cache: cache,
                catalog: catalog,
                keys: keys,
                iterations: iterations,
                isConcurrent: true
            ),
        ]

        for result in results {
            let milliseconds = result.duration.seconds * 1_000
            print(
                "\(result.name): \(String(format: "%.2f", result.operationsPerSecond)) ops/s "
                    + "(\(String(format: "%.2f", milliseconds)) ms, \(result.iterations) operations)"
            )
        }
    }

    private static func runFeedPlannerBenchmark() {
        let itemCount = 64
        let planningIterations = 10_000
        let items = (0..<itemCount).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "item-\(index)"),
                source: .stream(
                    url: URL(string: "https://benchmark.invalid/\(index).m3u8")!,
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 512 * 1_024
            )
        }
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 4,
            maximumEstimatedPreparationBytes: 8 * 1_024 * 1_024,
            neighborPredictionHorizon: 4
        ))
        var samples: [Duration] = []
        samples.reserveCapacity(planningIterations)
        var previousPlan: FeedPlan?

        for iteration in 0..<planningIterations {
            let focusedIndex = iteration % itemCount
            let signal = FeedViewportSignal(
                generation: .init(rawValue: UInt64(iteration)),
                focusedItemID: items[focusedIndex].id,
                visibleItems: [
                    .init(itemID: items[focusedIndex].id, fraction: 1, distanceInViewports: 0)
                ],
                velocityInViewportsPerSecond: iteration.isMultiple(of: 2) ? 3 : -3,
                predictedDestinations: [
                    .init(itemID: items[(focusedIndex + 1) % itemCount].id, confidence: 0.9)
                ],
                observedAt: .milliseconds(iteration)
            )
            let start = clock.now
            do {
                previousPlan = try planner.makePlan(
                    items: items,
                    signal: signal,
                    previousPlan: previousPlan
                )
            } catch {
                preconditionFailure("Feed planning benchmark input is invalid: \(error)")
            }
            samples.append(start.duration(to: clock.now))
        }

        samples.sort()
        let p95 = samples[(samples.count * 95) / 100]
        let p95Milliseconds = p95.seconds * 1_000
        print(
            "feed-planning-p95: \(String(format: "%.4f", p95Milliseconds)) ms "
                + "(\(planningIterations) updates, gate <= 1.0000 ms)"
        )
        precondition(p95 <= .milliseconds(1), "Feed planning p95 exceeded the 1 ms release gate")
    }

    private static func benchmark(
        name: String,
        iterations: Int,
        operation: @Sendable (Int) async -> Void
    ) async -> BenchmarkResult {
        let start = clock.now
        for index in 0..<iterations {
            await operation(index)
        }
        return BenchmarkResult(
            name: name,
            iterations: iterations,
            duration: start.duration(to: clock.now)
        )
    }

    private static func cachedRequestBenchmark(
        cache: HLSSegmentCache,
        catalog: SegmentCatalog,
        keys: [String],
        iterations: Int,
        isConcurrent: Bool
    ) async -> BenchmarkResult {
        let scheduler = SegmentPrefetchScheduler()
        let handler = SegmentHandler(
            cache: cache,
            catalog: catalog,
            fetcher: UnusedSegmentSource(),
            scheduler: scheduler
        ).makeHandler()
        let requests = keys.map { key in
            HTTPRequest(
                method: .get,
                path: "/segments/\(key)",
                headers: [:],
                body: Data()
            )
        }
        if isConcurrent {
            return await concurrentBenchmark(
                name: "concurrent-cached-segment-request",
                iterations: iterations
            ) { index in
                _ = await handler(requests[index % requests.count])
            }
        } else {
            return await benchmark(name: "cached-segment-request", iterations: iterations) { index in
                _ = await handler(requests[index % requests.count])
            }
        }
    }

    private static func concurrentBenchmark(
        name: String,
        iterations: Int,
        workers: Int = 8,
        operation: @escaping @Sendable (Int) async -> Void
    ) async -> BenchmarkResult {
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    var index = worker
                    while index < iterations {
                        await operation(index)
                        index += workers
                    }
                }
            }
        }
        return BenchmarkResult(
            name: name,
            iterations: iterations,
            duration: start.duration(to: clock.now)
        )
    }
}
