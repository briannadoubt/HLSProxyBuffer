import Foundation
import CryptoKit

public enum SegmentIdentity {
    public static func key(for segment: HLSSegment, namespace: String? = nil) -> String {
        let suffix = "segment-\(segment.sequence)-\(fingerprint(url: segment.url, range: segment.byteRange)).\(resourceExtension(for: segment.url))"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func key(forSequence sequence: Int, namespace: String? = nil) -> String {
        let suffix = "segment-\(sequence)"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func key(for part: HLSPartialSegment, namespace: String? = nil) -> String {
        let suffix = "part-\(part.parentSequence)-\(part.partIndex)-\(fingerprint(url: part.url, range: part.byteRange)).\(resourceExtension(for: part.url))"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func key(forPartSequence sequence: Int, partIndex: Int, namespace: String? = nil) -> String {
        let suffix = "part-\(sequence)-\(partIndex)"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func key(for map: MediaInitializationMap, namespace: String? = nil) -> String {
        let suffix = "map-\(fingerprint(url: map.uri, range: map.byteRange)).\(resourceExtension(for: map.uri))"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func key(for hint: HLSPreloadHint, namespace: String? = nil) -> String {
        let suffix = "hint-\(hint.sequence)-\(hint.partIndex ?? 0)-\(fingerprint(url: hint.uri, range: hint.byteRange)).\(resourceExtension(for: hint.uri))"
        return namespaced(suffix: suffix, namespace: namespace)
    }

    public static func sequence(from key: String) -> Int? {
        if let range = key.range(of: "segment-") {
            let digits = key[range.upperBound...].prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        if let range = key.range(of: "part-") {
            let tail = key[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        let digits = key.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    public static func namespace(from key: String) -> String? {
        if let range = key.range(of: "segment-") ?? key.range(of: "part-") {
            let prefix = key[..<range.lowerBound]
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    public static func partInfo(from key: String) -> (sequence: Int, partIndex: Int)? {
        guard let range = key.range(of: "part-") else { return nil }
        let tail = key[range.upperBound...]
        let components = tail.split(separator: "-", maxSplits: 1)
        guard components.count == 2,
              let sequence = Int(components[0]),
              let partIndex = Int(components[1].prefix { $0.isNumber }) else {
            return nil
        }
        return (sequence, partIndex)
    }

    private static func sanitize(_ namespace: String) -> String {
        namespace
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber {
                    return character
                }
                return "-"
            }
            .reduce(into: "") { partial, character in
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func namespaced(suffix: String, namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty else { return suffix }
        let sanitized = sanitize(namespace)
        guard !sanitized.isEmpty else { return suffix }
        return "\(sanitized)-\(suffix)"
    }

    private static func fingerprint(url: URL, range: ClosedRange<Int>?) -> String {
        let rangeValue = range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "full"
        let value = "\(url.absoluteString)|\(rangeValue)"
        return SHA256.hash(data: Data(value.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func resourceExtension(for url: URL) -> String {
        let value = url.pathExtension.lowercased().filter { character in
            character.isLetter || character.isNumber
        }
        return value.isEmpty ? "bin" : String(value.prefix(12))
    }
}
