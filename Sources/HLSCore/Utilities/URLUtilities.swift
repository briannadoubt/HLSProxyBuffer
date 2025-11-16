import Foundation

enum URLUtilities {
    static func resolve(_ string: String, baseURL: URL?) throws -> URL {
        if let url = URL(string: string), url.scheme != nil {
            return url
        }

        guard let baseURL else {
            throw URLError(.badURL)
        }

        if let url = URL(string: string, relativeTo: baseURL)?.absoluteURL {
            return url
        }

        throw URLError(.badURL)
    }
}
