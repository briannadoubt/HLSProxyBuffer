import Foundation

public enum SegmentIdentity {
    public static func key(for segment: HLSSegment) -> String {
        key(forSequence: segment.sequence)
    }

    public static func key(forSequence sequence: Int) -> String {
        "segment-\(sequence)"
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
}
