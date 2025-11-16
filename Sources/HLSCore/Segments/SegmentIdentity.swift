import Foundation

public enum SegmentIdentity {
    public static func key(for segment: HLSSegment, namespace: String? = nil) -> String {
        key(forSequence: segment.sequence, namespace: namespace)
    }

    public static func key(forSequence sequence: Int, namespace: String? = nil) -> String {
        let suffix = "segment-\(sequence)"
        guard let namespace, !namespace.isEmpty else { return suffix }
        let sanitized = sanitize(namespace)
        guard !sanitized.isEmpty else { return suffix }
        return "\(sanitized)-\(suffix)"
    }

    public static func sequence(from key: String) -> Int? {
        if let range = key.range(of: "segment-") {
            let digits = key[range.upperBound...].prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        let digits = key.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    public static func namespace(from key: String) -> String? {
        guard let range = key.range(of: "segment-") else { return nil }
        let prefix = key[..<range.lowerBound]
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
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
}
