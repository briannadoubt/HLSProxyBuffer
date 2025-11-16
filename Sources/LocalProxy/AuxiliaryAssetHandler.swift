import Foundation
import HLSCore

public struct AuxiliaryAssetHandler: Sendable {
    private let store: AuxiliaryAssetStore

    public init(store: AuxiliaryAssetStore) {
        self.store = store
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 3,
                  let type = AuxiliaryAssetType(rawValue: String(parts[1])),
                  let identifier = parts.last
            else {
                return HTTPResponse(status: .notFound)
            }

            if let data = await store.data(for: String(identifier), type: type) {
                return HTTPResponse(
                    status: .ok,
                    headers: [
                        "Content-Type": contentType(for: type),
                        "Cache-Control": cacheControl(for: type)
                    ],
                    body: data
                )
            }

            return HTTPResponse(status: .notFound)
        }
    }

    private func contentType(for type: AuxiliaryAssetType) -> String {
        switch type {
        case .audio:
            return "audio/aac"
        case .subtitles:
            return "text/vtt"
        case .keys:
            return "application/octet-stream"
        }
    }

    private func cacheControl(for type: AuxiliaryAssetType) -> String {
        switch type {
        case .keys:
            return "private, max-age=0, no-store"
        case .audio, .subtitles:
            return "public, max-age=60"
        }
    }
}
