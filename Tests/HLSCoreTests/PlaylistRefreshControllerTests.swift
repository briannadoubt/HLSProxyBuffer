import XCTest
@testable import HLSCore

final class PlaylistRefreshControllerTests: XCTestCase {
    func testDeliversUpdatesAndMetrics() async throws {
        let loader = PlaylistRefreshMockLoader()
        await loader.enqueue(string: samplePlaylist(sequence: 0))
        await loader.enqueue(string: samplePlaylist(sequence: 2))

        let controller = makeController(interval: 0.05, loader: loader)
        let url = URL(string: "https://example.com/live.m3u8")!
        let expectation = expectation(description: "playlist refresh")
        expectation.expectedFulfillmentCount = 2
        var deliveredSequences: [Int] = []

        await controller.start(
            url: url,
            allowInsecure: false,
            retryPolicy: .init(maxAttempts: 1, retryDelay: 0),
            onUpdate: { playlist in
                await MainActor.run {
                    deliveredSequences.append(playlist.mediaSequence)
                    expectation.fulfill()
                }
            }
        )

        await fulfillment(of: [expectation], timeout: 2)
        await controller.stop()

        let metrics = await controller.metrics()
        XCTAssertNotNil(metrics.lastRefreshDate)
        XCTAssertEqual(metrics.remoteMediaSequence, deliveredSequences.last)
        XCTAssertEqual(metrics.consecutiveFailures, 0)
    }

    func testStopsAfterEndlist() async throws {
        let loader = PlaylistRefreshMockLoader()
        await loader.enqueue(string: samplePlaylist(sequence: 5, endList: true))
        let controller = makeController(interval: 0.01, loader: loader)
        let url = URL(string: "https://example.com/vod.m3u8")!
        let expectation = expectation(description: "single refresh")

        await controller.start(
            url: url,
            allowInsecure: false,
            retryPolicy: .init(maxAttempts: 1, retryDelay: 0),
            onUpdate: { playlist in
                await MainActor.run {
                    XCTAssertTrue(playlist.isEndlist)
                    expectation.fulfill()
                }
            }
        )

        await fulfillment(of: [expectation], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let requestsServed = await loader.requestCount()
        XCTAssertEqual(requestsServed, 1)
        await controller.stop()
    }

    func testBlockingReloadAddsQueryParametersWhenEnabled() async throws {
        let loader = PlaylistRefreshMockLoader()
        await loader.enqueue(string: lowLatencyPlaylist(sequence: 10))
        await loader.enqueue(string: lowLatencyPlaylist(sequence: 11))

        let controller = makeController(interval: 0.01, loader: loader)
        await controller.updateLowLatencyConfiguration(.init(isEnabled: true, blockingRequestTimeout: 0.2, enableDeltaUpdates: true))
        let url = URL(string: "https://example.com/live.m3u8")!
        let expectation = expectation(description: "blocking refresh")
        expectation.expectedFulfillmentCount = 2

        await controller.start(
            url: url,
            allowInsecure: false,
            retryPolicy: .init(maxAttempts: 1, retryDelay: 0),
            onUpdate: { _ in await MainActor.run { expectation.fulfill() } }
        )

        await fulfillment(of: [expectation], timeout: 2)
        await controller.stop()

        let requests = await loader.recordedRequests()
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        let blockingRequest = try XCTUnwrap(requests.dropFirst().first)
        let components = try XCTUnwrap(URLComponents(url: blockingRequest, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(queryItems["_HLS_msn"], "11")
        XCTAssertEqual(queryItems["_HLS_part"], "1")
        XCTAssertEqual(queryItems["_HLS_skip"], "YES")
    }

    private func makeController(interval: TimeInterval, loader: PlaylistRefreshMockLoader) -> PlaylistRefreshController {
        PlaylistRefreshController(
            configuration: .init(refreshInterval: interval, maxBackoffInterval: interval * 2),
            logger: TestLogger(),
            manifestLoader: { url, _, _ in
                try await loader.next(for: url)
            }
        )
    }

    private func samplePlaylist(sequence: Int, endList: Bool = false) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:\(sequence)"]
        lines.append(contentsOf: ["#EXTINF:3.0,", "segment-\(sequence).ts"])
        if endList {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n")
    }

    private func lowLatencyPlaylist(sequence: Int) -> String {
        let next = sequence + 1
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.5",
            "#EXT-X-PART-INF:PART-TARGET=0.5",
            "#EXT-X-TARGETDURATION:4",
            "#EXT-X-MEDIA-SEQUENCE:\(sequence)",
            "#EXTINF:4.0,",
            "seg-\(sequence).ts",
            "#EXT-X-PART:DURATION=0.5,URI=\"seg-\(next)-part0.ts\"",
            "#EXT-X-PART:DURATION=0.5,URI=\"seg-\(next)-part1.ts\"",
            "#EXTINF:4.0,",
            "seg-\(next).ts"
        ].joined(separator: "\n")
    }
}

private actor PlaylistRefreshMockLoader {
    private enum Stub {
        case success(String)
        case failure(Error)
    }

    private var stubs: [Stub] = []
    private var requests: [URL] = []

    func enqueue(string: String) {
        stubs.append(.success(string))
    }

    func enqueue(error: Error) {
        stubs.append(.failure(error))
    }

    func next(for url: URL) throws -> String {
        requests.append(url)
        guard !stubs.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let stub = stubs.removeFirst()
        switch stub {
        case .success(let string):
            return string
        case .failure(let error):
            throw error
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func recordedRequests() -> [URL] {
        requests
    }
}

private struct TestLogger: Logger {
    func log(_ message: @autoclosure () -> String, category: LogCategory) {}
}
