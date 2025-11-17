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
                let entry = await catalog.segmentEntry(forKey: key)
                return await successResponse(with: data, key: key, entry: entry)
            }

            guard let entry = await catalog.segmentEntry(forKey: key) else {
                return HTTPResponse(status: .serviceUnavailable)
            }

            if let data = await fetchAndCache(entry: entry, key: key) {
                return await successResponse(with: data, key: key, entry: entry)
            }

            return HTTPResponse(status: .serviceUnavailable)
        }
    }

    private func successResponse(with data: Data, key: String, entry: SegmentCatalog.Entry?) async -> HTTPResponse {
        let response = HTTPResponse(
            status: .ok,
            headers: [
                "Content-Type": "video/mp2t",
                "Connection": "close",
            ],
            body: data
        )
        if entry?.namespace == SegmentCatalog.Namespace.primary {
            if let payload = entry?.payload {
                switch payload {
                case .segment:
                    if let sequence = SegmentIdentity.sequence(from: key) {
                        onSegmentServed?(sequence)
                        await scheduler.consume(sequence: sequence)
                    }
                case .part:
                    if let info = SegmentIdentity.partInfo(from: key) {
                        await scheduler.consumePart(sequence: info.sequence, partIndex: info.partIndex)
                    }
                }
            }
        }
        return response
    }

    private func fetchAndCache(entry: SegmentCatalog.Entry, key: String) async -> Data? {
        do {
            let data: Data
            switch entry.payload {
            case .segment(let segment):
                data = try await fetcher.fetchSegment(segment)
            case .part(let part):
                data = try await fetcher.fetchPartialSegment(part)
            }
            await cache.put(data, for: key)
            if entry.namespace == SegmentCatalog.Namespace.primary {
                switch entry.payload {
                case .segment(let segment):
                    await scheduler.registerReadySegment(segment)
                case .part(let part):
                    await scheduler.registerReadyPart(part)
                }
            }
            return data
        } catch {
            return nil
        }
    }
}
