import Foundation
import HLSCore

public struct SegmentHandler: Sendable {
    private let cache: HLSSegmentCache
    private let catalog: SegmentCatalog
    private let fetcher: any SegmentSource
    private let scheduler: SegmentPrefetchScheduler
    private let onSegmentServed: (@Sendable (Int) -> Void)?

    public init(
        cache: HLSSegmentCache,
        catalog: SegmentCatalog,
        fetcher: any SegmentSource,
        scheduler: SegmentPrefetchScheduler,
        onSegmentServed: (@Sendable (Int) -> Void)? = nil
    ) {
        self.cache = cache
        self.catalog = catalog
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.onSegmentServed = onSegmentServed
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            guard let identifier = request.path.split(separator: "/").last else {
                return HTTPResponse(status: .notFound)
            }
            let key = String(identifier)

            if let data = await cache.get(key) {
                return await successResponse(with: data, key: key)
            }

            if let data = await fetchAndCache(key: key) {
                return await successResponse(with: data, key: key)
            }

            return HTTPResponse(status: .serviceUnavailable)
        }
    }

    private func successResponse(with data: Data, key: String) async -> HTTPResponse {
        let response = HTTPResponse(
            status: .ok,
            headers: [
                "Content-Type": "video/mp2t",
                "Connection": "close",
            ],
            body: data
        )
        if let sequence = SegmentIdentity.sequence(from: key) {
            onSegmentServed?(sequence)
            await scheduler.consume(sequence: sequence)
        }
        return response
    }

    private func fetchAndCache(key: String) async -> Data? {
        guard
            let sequence = SegmentIdentity.sequence(from: key),
            let segment = await catalog.segment(forSequence: sequence)
        else {
            return nil
        }

        do {
            let data = try await fetcher.fetchSegment(segment)
            await cache.put(data, for: key)
            await scheduler.registerReadySegment(segment)
            return data
        } catch {
            return nil
        }
    }
}
