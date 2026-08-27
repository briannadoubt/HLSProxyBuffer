import Foundation
import HLSCore

public actor PlaylistStore {
    public struct Snapshot: Sendable {
        public let text: String
        public let revision: UInt64
    }

    public enum Identifier {
        public static let master = "master"
        public static let primaryVariant = "variant-primary"

        public static func rendition(_ name: String) -> String {
            "rendition-\(name)"
        }
    }

    private var playlists: [String: String]
    private var revisions: [String: UInt64] = [:]
    private var continuations: [String: [UUID: AsyncStream<Snapshot>.Continuation]] = [:]
    private let defaultPlaylist: String

    public init(defaultPlaylist: String = "#EXTM3U\n#EXT-X-ENDLIST") {
        self.defaultPlaylist = defaultPlaylist
        self.playlists = [:]
    }

    public func update(_ text: String, for identifier: String = Identifier.master) {
        playlists[identifier] = text
        let revision = (revisions[identifier] ?? 0) &+ 1
        revisions[identifier] = revision
        let snapshot = Snapshot(text: text, revision: revision)
        if let bucket = continuations[identifier] {
            for continuation in bucket.values {
                continuation.yield(snapshot)
            }
        }
    }

    public func snapshot(for identifier: String = Identifier.master) -> String {
        playlists[identifier] ?? defaultPlaylist
    }

    public func snapshot(
        for identifier: String = Identifier.master,
        waitingForMediaSequence mediaSequence: Int,
        part: Int?,
        timeout: TimeInterval
    ) async -> String {
        let current = Snapshot(
            text: playlists[identifier] ?? defaultPlaylist,
            revision: revisions[identifier] ?? 0
        )
        if Self.isAvailable(mediaSequence: mediaSequence, part: part, in: current.text) {
            return current.text
        }
        let updates = updateStream(for: identifier)
        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await update in updates {
                    if Self.isAvailable(mediaSequence: mediaSequence, part: part, in: update.text) {
                        return update.text
                    }
                    if Task.isCancelled { return nil }
                }
                return nil
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return nil
                }
                return await self.snapshot(for: identifier)
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? current.text
        }
    }

    public func remove(_ identifier: String) {
        playlists.removeValue(forKey: identifier)
        revisions.removeValue(forKey: identifier)
    }

    private func updateStream(for identifier: String) -> AsyncStream<Snapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var bucket = continuations[identifier] ?? [:]
            bucket[id] = continuation
            continuations[identifier] = bucket
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id, for: identifier) }
            }
        }
    }

    private func removeContinuation(_ id: UUID, for identifier: String) {
        continuations[identifier]?.removeValue(forKey: id)
    }

    private static func isAvailable(mediaSequence requestedMSN: Int, part requestedPart: Int?, in text: String) -> Bool {
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        let mediaSequence = lines
            .first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
            .flatMap { Int($0.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) } ?? 0
        let skippedCount = lines
            .first(where: { $0.hasPrefix("#EXT-X-SKIP:") })
            .flatMap { line -> Int? in
                line.split(separator: ",")
                    .first(where: { $0.contains("SKIPPED-SEGMENTS=") })
                    .flatMap { Int($0.split(separator: "=", maxSplits: 1).last ?? "") }
            } ?? 0
        let completeCount = lines.filter { $0.hasPrefix("#EXTINF:") }.count
        let lastComplete = mediaSequence + skippedCount + completeCount - 1
        if requestedMSN <= lastComplete { return true }
        guard requestedMSN == lastComplete + 1, let requestedPart else { return false }

        var trailingPartCount = 0
        var sawLastCompleteURI = completeCount == 0
        var extinfRemaining = completeCount
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                sawLastCompleteURI = false
            } else if !line.hasPrefix("#"), !line.isEmpty, extinfRemaining > 0 {
                extinfRemaining -= 1
                sawLastCompleteURI = extinfRemaining == 0
                trailingPartCount = 0
            } else if sawLastCompleteURI, line.hasPrefix("#EXT-X-PART:") {
                trailingPartCount += 1
            }
        }
        return requestedPart < trailingPartCount
    }
}

public struct PlaylistHandler: Sendable {
    private let store: PlaylistStore
    private let identifier: String
    private let onServe: (@Sendable () -> Void)?
    private let blockingReloadTimeout: TimeInterval

    public init(
        store: PlaylistStore,
        identifier: String = PlaylistStore.Identifier.master,
        blockingReloadTimeout: TimeInterval = 6,
        onServe: (@Sendable () -> Void)? = nil
    ) {
        self.store = store
        self.identifier = identifier
        self.blockingReloadTimeout = blockingReloadTimeout
        self.onServe = onServe
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            guard request.method == .get || request.method == .head else {
                return HTTPResponse(status: .methodNotAllowed, headers: ["Allow": "GET, HEAD"])
            }
            _ = request
            let text: String
            if let value = request.queryItems["_HLS_msn"], let mediaSequence = Int(value) {
                let part = request.queryItems["_HLS_part"].flatMap(Int.init)
                text = await store.snapshot(
                    for: identifier,
                    waitingForMediaSequence: mediaSequence,
                    part: part,
                    timeout: blockingReloadTimeout
                )
            } else {
                text = await store.snapshot(for: identifier)
            }
            onServe?()
            return HTTPResponse.text(text)
        }
    }
}

public struct RenditionPlaylistHandler: Sendable {
    private let store: PlaylistStore
    private let blockingReloadTimeout: TimeInterval

    public init(store: PlaylistStore, blockingReloadTimeout: TimeInterval = 6) {
        self.store = store
        self.blockingReloadTimeout = blockingReloadTimeout
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            guard request.method == .get || request.method == .head else {
                return HTTPResponse(status: .methodNotAllowed, headers: ["Allow": "GET, HEAD"])
            }
            guard let last = request.path.split(separator: "/").last else {
                return HTTPResponse(status: .notFound)
            }
            let identifier = sanitizedIdentifier(from: String(last))
            let playlistIdentifier = PlaylistStore.Identifier.rendition(identifier)
            let text: String
            if let value = request.queryItems["_HLS_msn"], let mediaSequence = Int(value) {
                text = await store.snapshot(
                    for: playlistIdentifier,
                    waitingForMediaSequence: mediaSequence,
                    part: request.queryItems["_HLS_part"].flatMap(Int.init),
                    timeout: blockingReloadTimeout
                )
            } else {
                text = await store.snapshot(for: playlistIdentifier)
            }
            return HTTPResponse.text(text)
        }
    }

    private func sanitizedIdentifier(from component: String) -> String {
        component
            .replacingOccurrences(of: ".m3u8", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
