import Foundation
import HLSCore
import os

public struct SegmentHandler: Sendable {
    private let cache: HLSSegmentCache
    private let catalog: SegmentCatalog
    private let fetcher: any SegmentSource
    private let scheduler: SegmentPrefetchScheduler
    private let onSegmentServed: (@Sendable (Int) -> Void)?
    private let loadCoordinator = SegmentLoadCoordinator()
    private let servedTracker = ServedResourceTracker()

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
            guard request.method == .get || request.method == .head else {
                return HTTPResponse(status: .methodNotAllowed, headers: ["Allow": "GET, HEAD"])
            }
            guard let identifier = request.path.split(separator: "/").last else {
                return HTTPResponse(status: .notFound)
            }
            let key = String(identifier)
            let entry = await catalog.segmentEntry(forKey: key)

            let data: Data
            if let cached = await cache.get(key) {
                data = cached
            } else {
                guard let entry else { return HTTPResponse(status: .notFound) }
                do {
                    data = try await loadCoordinator.data(for: key) {
                        let fetched = try await fetch(entry: entry)
                        try Task.checkCancellation()
                        await cache.put(fetched, for: key)
                        await registerReady(entry)
                        return fetched
                    }
                } catch {
                    return HTTPResponse(status: .serviceUnavailable)
                }
            }

            return await successResponse(
                with: data,
                key: key,
                entry: entry,
                request: request
            )
        }
    }

    private func successResponse(
        with data: Data,
        key: String,
        entry: SegmentCatalog.Entry?,
        request: HTTPRequest
    ) async -> HTTPResponse {
        let rangeResult = requestedRange(request.headers["range"], totalLength: data.count)
        let status: HTTPResponse.Status
        let body: Data
        var headers: [String: String] = [
            "Content-Type": contentType(for: entry),
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, max-age=31536000, immutable"
        ]

        switch rangeResult {
        case .none:
            status = .ok
            body = data
        case .valid(let range):
            status = .partialContent
            body = data.subdata(in: range.lowerBound..<(range.upperBound + 1))
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)"
        case .invalid:
            return HTTPResponse(
                status: .rangeNotSatisfiable,
                headers: ["Content-Range": "bytes */\(data.count)", "Accept-Ranges": "bytes"]
            )
        }

        if request.method == .get,
           entry?.namespace == SegmentCatalog.Namespace.primary,
           servedTracker.markFirstDelivery(for: key),
           let payload = entry?.payload {
            switch payload {
            case .segment(let segment):
                onSegmentServed?(segment.sequence)
            case .part:
                break
            case .initializationMap, .preloadHint:
                break
            }
        }

        return HTTPResponse(status: status, headers: headers, body: body)
    }

    private func fetch(entry: SegmentCatalog.Entry) async throws -> Data {
        switch entry.payload {
        case .segment(let segment):
            return try await fetcher.fetchSegment(segment)
        case .part(let part):
            return try await fetcher.fetchPartialSegment(part)
        case .initializationMap(let map):
            return try await fetcher.fetchResource(at: map.uri, byteRange: map.byteRange)
        case .preloadHint(let hint):
            return try await fetcher.fetchResource(at: hint.uri, byteRange: hint.byteRange)
        }
    }

    private func registerReady(_ entry: SegmentCatalog.Entry) async {
        guard entry.namespace == SegmentCatalog.Namespace.primary else { return }
        switch entry.payload {
        case .segment(let segment):
            await scheduler.registerReadySegment(segment)
        case .part(let part):
            await scheduler.registerReadyPart(part)
        case .initializationMap, .preloadHint:
            break
        }
    }

    private func contentType(for entry: SegmentCatalog.Entry?) -> String {
        let url: URL?
        switch entry?.payload {
        case .segment(let segment): url = segment.url
        case .part(let part): url = part.url
        case .initializationMap(let map): url = map.uri
        case .preloadHint(let hint): url = hint.uri
        case nil: url = nil
        }
        switch url?.pathExtension.lowercased() {
        case "m4s", "mp4", "cmfv": return "video/mp4"
        case "cmfa", "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "mp3": return "audio/mpeg"
        case "vtt": return "text/vtt"
        case "webvtt": return "text/vtt"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return "video/mp2t"
        }
    }

    private enum RangeResult {
        case none
        case valid(ClosedRange<Int>)
        case invalid
    }

    private func requestedRange(_ header: String?, totalLength: Int) -> RangeResult {
        guard let header else { return .none }
        guard totalLength > 0, header.lowercased().hasPrefix("bytes=") else { return .invalid }
        let value = header.dropFirst("bytes=".count)
        guard !value.contains(",") else { return .invalid }
        let components = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return .invalid }

        if components[0].isEmpty {
            guard let suffixLength = Int(components[1]), suffixLength > 0 else { return .invalid }
            let length = min(suffixLength, totalLength)
            return .valid((totalLength - length)...(totalLength - 1))
        }

        guard let start = Int(components[0]), start >= 0, start < totalLength else { return .invalid }
        if components[1].isEmpty {
            return .valid(start...(totalLength - 1))
        }
        guard let requestedEnd = Int(components[1]), requestedEnd >= start else { return .invalid }
        return .valid(start...min(requestedEnd, totalLength - 1))
    }
}

actor SegmentLoadCoordinator {
    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Data, Error>]
    }

    private var inFlight: [String: InFlight] = [:]

    func waiterCount(for key: String) -> Int { inFlight[key]?.waiters.count ?? 0 }

    func data(
        for key: String,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var entry = inFlight[key] {
                    entry.waiters[waiterID] = continuation
                    inFlight[key] = entry
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<Data, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        finish(key: key, id: id, result: result)
                    }
                    inFlight[key] = InFlight(
                        id: id, task: task, waiters: [waiterID: continuation]
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiterID: waiterID) }
        }
    }

    private func cancel(key: String, waiterID: UUID) {
        guard var entry = inFlight[key],
              let continuation = entry.waiters.removeValue(forKey: waiterID)
        else { return }
        if entry.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlight[key] = entry
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(key: String, id: UUID, result: Result<Data, Error>) {
        guard let entry = inFlight[key], entry.id == id else { return }
        inFlight.removeValue(forKey: key)
        for continuation in entry.waiters.values { continuation.resume(with: result) }
    }
}

private final class ServedResourceTracker: Sendable {
    private let delivered = OSAllocatedUnfairLock(initialState: Set<String>())

    func markFirstDelivery(for key: String) -> Bool {
        delivered.withLock { $0.insert(key).inserted }
    }
}
