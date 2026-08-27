import Foundation
import HLSCore

public struct AuxiliaryAssetHandler: Sendable {
    private let store: AuxiliaryAssetStore

    public init(store: AuxiliaryAssetStore) {
        self.store = store
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            guard request.method == .get || request.method == .head else {
                return HTTPResponse(status: .methodNotAllowed, headers: ["Allow": "GET, HEAD"])
            }
            let parts = request.path.split(separator: "/")
            guard parts.count >= 3,
                  let type = AuxiliaryAssetType(rawValue: String(parts[1])),
                  let identifier = parts.last
            else {
                return HTTPResponse(status: .notFound)
            }

            if let data = await store.data(for: String(identifier), type: type) {
                let range = parsedRange(request.headers["range"], totalLength: data.count)
                let body: Data
                let status: HTTPResponse.Status
                var headers = [
                    "Content-Type": contentType(for: type),
                    "Cache-Control": cacheControl(for: type),
                    "Accept-Ranges": "bytes"
                ]
                switch range {
                case .none:
                    status = .ok
                    body = data
                case .some(let range):
                    guard let range else {
                        return HTTPResponse(
                            status: .rangeNotSatisfiable,
                            headers: [
                                "Content-Range": "bytes */\(data.count)",
                                "Accept-Ranges": "bytes"
                            ]
                        )
                    }
                    status = .partialContent
                    body = data.subdata(in: range.lowerBound..<(range.upperBound + 1))
                    headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)"
                }
                return HTTPResponse(
                    status: status,
                    headers: headers,
                    body: body
                )
            }

            return HTTPResponse(status: .notFound)
        }
    }

    /// nil means no range; `.some(nil)` means malformed or unsatisfiable.
    private func parsedRange(_ header: String?, totalLength: Int) -> ClosedRange<Int>?? {
        guard let header else { return nil }
        guard totalLength > 0, header.lowercased().hasPrefix("bytes=") else { return .some(nil) }
        let components = header.dropFirst("bytes=".count)
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return .some(nil) }
        if components[0].isEmpty {
            guard let suffixLength = Int(components[1]), suffixLength > 0 else { return .some(nil) }
            let length = min(suffixLength, totalLength)
            return .some((totalLength - length)...(totalLength - 1))
        }
        guard let start = Int(components[0]), start >= 0, start < totalLength else { return .some(nil) }
        let end = components[1].isEmpty ? totalLength - 1 : min(Int(components[1]) ?? -1, totalLength - 1)
        guard end >= start else { return .some(nil) }
        return .some(start...end)
    }

    private func contentType(for type: AuxiliaryAssetType) -> String {
        switch type {
        case .audio:
            return "audio/aac"
        case .subtitles:
            return "text/vtt"
        case .keys:
            return "application/octet-stream"
        case .metadata:
            return "application/octet-stream"
        }
    }

    private func cacheControl(for type: AuxiliaryAssetType) -> String {
        switch type {
        case .keys:
            return "private, max-age=0, no-store"
        case .audio, .subtitles, .metadata:
            return "public, max-age=60"
        }
    }
}
