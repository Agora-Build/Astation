import Foundation

enum StationRelayURL {
    static func normalizedBase(_ value: String) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    static func webSocketURL(base: String, code: String) -> URL? {
        guard var components = URLComponents(string: normalizedBase(base)),
              let host = components.host, !host.isEmpty else { return nil }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: return nil
        }
        components.percentEncodedPath += "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "astation"),
            URLQueryItem(name: "code", value: code)
        ]
        components.fragment = nil
        return components.url
    }
}
