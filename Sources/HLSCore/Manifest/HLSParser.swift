import Foundation

public struct HLSParser: Sendable {
    public enum ParserError: Error, CustomStringConvertible {
        case missingHeader
        case malformedEXTINF(String)
        case missingURIAfterTag(String)
        case unresolvedURL(String)

        public var description: String {
            switch self {
            case .missingHeader:
                return "Playlist must start with #EXTM3U."
            case .malformedEXTINF(let value):
                return "Unable to parse EXTINF duration: \(value)."
            case .missingURIAfterTag(let tag):
                return "Expected URI following \(tag)."
            case .unresolvedURL(let value):
                return "Unable to resolve URL: \(value)."
            }
        }
    }

    private let logger: Logger

    public init(logger: Logger = DefaultLogger()) {
        self.logger = logger
    }

    public func parse(_ text: String, baseURL: URL?) throws -> HLSManifest {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.first == "#EXTM3U" || lines.contains("#EXTM3U") else {
            throw ParserError.missingHeader
        }

        var variants: [VariantPlaylist] = []
        var segments: [HLSSegment] = []
        var pendingVariantAttributes: VariantPlaylist.Attributes?
        var pendingDuration: TimeInterval?
        var pendingByteRange: ClosedRange<Int>?
        var currentSequence = 0
        var targetDuration: TimeInterval?

        for line in lines {
            guard !line.isEmpty else { continue }

            if line == "#EXTM3U" {
                continue
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.replacingOccurrences(of: "#EXTINF:", with: "")
                guard let duration = TimeInterval(value.split(separator: ",").first ?? "") else {
                    throw ParserError.malformedEXTINF(value)
                }
                pendingDuration = duration
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let value = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                pendingVariantAttributes = parseVariantAttributes(from: value)
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = line.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")
                currentSequence = Int(value) ?? currentSequence
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let value = line.replacingOccurrences(of: "#EXT-X-TARGETDURATION:", with: "")
                targetDuration = TimeInterval(value)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let value = line.replacingOccurrences(of: "#EXT-X-BYTERANGE:", with: "")
                pendingByteRange = parseByteRange(from: value)
            } else if line.hasPrefix("#") {
                continue
            } else {
                if let attributes = pendingVariantAttributes {
                    let url = try resolveURL(line, baseURL: baseURL)
                    variants.append(VariantPlaylist(url: url, attributes: attributes))
                    pendingVariantAttributes = nil
                } else {
                    let url = try resolveURL(line, baseURL: baseURL)
                    let duration = pendingDuration ?? 0

                    segments.append(
                        HLSSegment(
                            url: url,
                            duration: duration,
                            sequence: currentSequence,
                            byteRange: pendingByteRange
                        )
                    )
                    pendingDuration = nil
                    pendingByteRange = nil
                    currentSequence += 1
                }
            }
        }

        let mediaPlaylist = segments.isEmpty ? nil : MediaPlaylist(
            targetDuration: targetDuration,
            mediaSequence: segments.first?.sequence ?? 0,
            segments: segments
        )

        let kind: HLSManifestKind = variants.isEmpty ? .media : .master

        logger.log("Parsed manifest – kind: \(kind), variants: \(variants.count), segments: \(segments.count)", category: .parser)

        return HLSManifest(
            kind: kind,
            variants: variants,
            mediaPlaylist: mediaPlaylist,
            originalText: text
        )
    }

    private func resolveURL(_ string: String, baseURL: URL?) throws -> URL {
        do {
            return try URLUtilities.resolve(string, baseURL: baseURL)
        } catch {
            throw ParserError.unresolvedURL(string)
        }
    }

    private func parseVariantAttributes(from string: String) -> VariantPlaylist.Attributes {
        var bandwidth: Int?
        var resolution: String?
        var codecs: String?

        let pairs = string.split(separator: ",")
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else { continue }
            let key = components[0].trimmingCharacters(in: .whitespaces)
            var value = components[1].trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            switch key.uppercased() {
            case "BANDWIDTH":
                bandwidth = Int(value)
            case "RESOLUTION":
                resolution = value
            case "CODECS":
                codecs = value
            default:
                continue
            }
        }

        return VariantPlaylist.Attributes(
            bandwidth: bandwidth,
            resolution: resolution,
            codecs: codecs
        )
    }

    private func parseByteRange(from string: String) -> ClosedRange<Int>? {
        let components = string.split(separator: "@")
        guard let length = Int(components.first ?? "") else { return nil }

        if components.count == 2, let offset = Int(components[1]) {
            return offset...(offset + length - 1)
        }

        return 0...(length - 1)
    }
}
