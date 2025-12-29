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
        let contentType = detectContentType(for: entry, data: data)
        let response = HTTPResponse(
            status: .ok,
            headers: [
                "Content-Type": contentType,
                "Connection": "keep-alive",
                "Cache-Control": "max-age=3600",
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

    private func detectContentType(for entry: SegmentCatalog.Entry?, data: Data) -> String {
        // Check URL extension first
        let url: URL?
        switch entry?.payload {
        case .segment(let segment):
            url = segment.url
        case .part(let part):
            url = part.url
        case .none:
            url = nil
        }

        if let url {
            let pathExtension = url.pathExtension.lowercased()
            switch pathExtension {
            case "m4s", "m4v", "m4a", "mp4", "cmfv", "cmfa":
                return "video/iso.segment"
            case "ts":
                return "video/mp2t"
            case "aac":
                return "audio/aac"
            case "vtt", "webvtt":
                return "text/vtt"
            default:
                break
            }
        }

        // Detect by magic bytes if URL doesn't help
        if data.count >= 8 {
            // Check for ftyp box (CMAF/MP4)
            let ftypSignature = Data([0x66, 0x74, 0x79, 0x70]) // "ftyp"
            if data.count >= 12 {
                let possibleFtyp = data[4..<8]
                if possibleFtyp == ftypSignature {
                    return "video/iso.segment"
                }
            }

            // Check for MPEG-TS sync byte
            if data[0] == 0x47 {
                return "video/mp2t"
            }
        }

        // Default to MPEG-TS for backwards compatibility
        return "video/mp2t"
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
