import Foundation

enum NetworkDebugLogger {
    private static let maxPayloadLength = 4000

    // Always on in Debug. In Release, enable with ASTATION_NETWORK_DEBUG=1/true.
    private static let isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        let value = ProcessInfo.processInfo.environment["ASTATION_NETWORK_DEBUG"]?.lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
        #endif
    }()

    static func logRequest(_ request: URLRequest, bodyOverride: Data? = nil, label: String? = nil) {
        guard isEnabled else { return }
        let method = request.httpMethod ?? "GET"
        let url = sanitizeURL(request.url)
        let headers = sanitizeHeaders(request.allHTTPHeaderFields ?? [:])
        let bodyData = bodyOverride ?? request.httpBody
        let body = formatBody(bodyData)
        Log.debug("[Net] \(labelPrefix(label))Request \(method) \(url)\nHeaders: \(headers)\nBody: \(body)")
    }

    static func logResponse(_ response: URLResponse?, data: Data?, label: String? = nil) {
        guard isEnabled else { return }
        guard let response else {
            Log.debug("[Net] \(labelPrefix(label))Response <nil>")
            return
        }
        if let http = response as? HTTPURLResponse {
            let headers = sanitizeHeaders(http.allHeaderFields)
            let body = formatBody(data)
            Log.debug("[Net] \(labelPrefix(label))Response \(http.statusCode)\nHeaders: \(headers)\nBody: \(body)")
        } else {
            Log.debug("[Net] \(labelPrefix(label))Response \(response)")
        }
    }

    static func logError(_ error: Error, label: String? = nil) {
        guard isEnabled else { return }
        Log.debug("[Net] \(labelPrefix(label))Error \(error)")
    }

    static func logWebSocket(direction: String, context: String, message: String) {
        guard isEnabled else { return }
        Log.debug("[WS] \(direction) \(context): \(sanitizedPayload(message))")
    }

    static func logWebSocketBinary(direction: String, context: String, size: Int) {
        guard isEnabled else { return }
        Log.debug("[WS] \(direction) \(context): <binary \(size) bytes>")
    }

    private static func labelPrefix(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        return "\(label) "
    }

    private static func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var sanitized = headers
        for key in headers.keys {
            let lower = key.lowercased()
            if lower == "authorization" || lower == "cookie" || lower == "set-cookie" {
                sanitized[key] = "<redacted>"
            }
        }
        return sanitized
    }

    private static func sanitizeHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            out[String(describing: k)] = String(describing: v)
        }
        return sanitizeHeaders(out)
    }

    private static func formatBody(_ data: Data?) -> String {
        guard let data else { return "<empty>" }
        if data.isEmpty { return "<empty>" }
        if let text = String(data: data, encoding: .utf8) {
            return sanitizedPayload(text)
        }
        return "<binary \(data.count) bytes>"
    }

    private static func truncate(_ text: String) -> String {
        if text.count <= maxPayloadLength { return text }
        let prefix = String(text.prefix(maxPayloadLength))
        let remaining = text.count - maxPayloadLength
        return "\(prefix)…<truncated \(remaining) chars>"
    }

    static func sanitizedPayload(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sanitizedData = try? JSONSerialization.data(
                withJSONObject: sanitizeJSONObject(object),
                options: [.sortedKeys]
              ),
              let sanitized = String(data: sanitizedData, encoding: .utf8) else {
            return sanitizeUnstructuredText(text)
        }
        return truncate(sanitized)
    }

    private static let sensitiveKeys: Set<String> = [
        "access_token", "api_key", "app_certificate", "auth_token", "authorization",
        "bearer", "bootstrap_token", "cookie", "credential", "encryption_key", "otp",
        "pairing_code", "password", "proof", "refresh_token", "secret", "session",
        "session_id", "session_token", "token"
    ]

    private static func sanitizeUnstructuredText(_ text: String) -> String {
        let replacements = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (
                #"(?i)\b(access[_-]?token|api[_-]?key|auth[_-]?token|bootstrap[_-]?token|otp|pairing[_-]?code|password|proof|refresh[_-]?token|secret|session[_-]?id|session[_-]?token|token)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"#,
                "$1=<redacted>"
            )
        ]
        let sanitized = replacements.reduce(text) { value, replacement in
            guard let expression = try? NSRegularExpression(
                pattern: replacement.0,
                options: []
            ) else { return value }
            return expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: replacement.1
            )
        }
        return truncate(sanitized)
    }

    private static func sanitizeJSONObject(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let normalizedKey = entry.key.lowercased().replacingOccurrences(of: "-", with: "_")
                result[entry.key] = sensitiveKeys.contains(normalizedKey)
                    ? "<redacted>"
                    : sanitizeJSONObject(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(sanitizeJSONObject)
        }
        return value
    }

    private static func sanitizeURL(_ url: URL?) -> String {
        guard let url else { return "(nil)" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return url.absoluteString
        }
        components.queryItems = items.map { item in
            let normalizedName = item.name.lowercased().replacingOccurrences(of: "-", with: "_")
            guard sensitiveKeys.contains(normalizedName) else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return components.string ?? url.absoluteString
    }
}
