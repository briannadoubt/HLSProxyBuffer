import Foundation

enum QualificationArtifact {
    static func write<Value: Encodable>(_ value: Value, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["HLS_CI_ARTIFACT_DIR"],
              !directory.isEmpty
        else {
            return
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(
            to: directoryURL.appendingPathComponent(name),
            options: .atomic
        )
    }
}
