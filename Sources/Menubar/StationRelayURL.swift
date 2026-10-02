import Foundation

enum StationRelayURL {
    static func normalizedBase(_ value: String) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    /// Returns a normalized relay base URL only when it can be used by the
    /// WebSocket client. Credentials, queries and fragments are not valid in a
    /// relay base URL and can make a pasted URL misleading.
    static func validatedBase(_ value: String) -> String? {
        let normalized = normalizedBase(value)
        guard !normalized.isEmpty,
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url != nil else { return nil }
        return normalized
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
