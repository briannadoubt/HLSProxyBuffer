import Foundation
import HLSCore
import LocalProxy

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
