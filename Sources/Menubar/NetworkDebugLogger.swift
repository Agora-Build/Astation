import Foundation

enum NetworkDebugLogger {
#if DEBUG
    private static let maxPayloadLength = 4000

    static func logRequest(_ request: URLRequest, bodyOverride: Data? = nil, label: String? = nil) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "(nil)"
        let headers = sanitizeHeaders(request.allHTTPHeaderFields ?? [:])
        let bodyData = bodyOverride ?? request.httpBody
        let body = formatBody(bodyData)
        Log.debug("[Net] \(labelPrefix(label))Request \(method) \(url)\nHeaders: \(headers)\nBody: \(body)")
    }

    static func logResponse(_ response: URLResponse?, data: Data?, label: String? = nil) {
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
        Log.debug("[Net] \(labelPrefix(label))Error \(error)")
    }

    static func logWebSocket(direction: String, context: String, message: String) {
        Log.debug("[WS] \(direction) \(context): \(truncate(message))")
    }

    static func logWebSocketBinary(direction: String, context: String, size: Int) {
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
            let key = String(describing: k)
            let value = String(describing: v)
            out[key] = value
        }
        return sanitizeHeaders(out)
    }

    private static func formatBody(_ data: Data?) -> String {
        guard let data else { return "<empty>" }
        if data.isEmpty { return "<empty>" }
        if let text = String(data: data, encoding: .utf8) {
            return truncate(text)
        }
        return "<binary \(data.count) bytes>"
    }

    private static func truncate(_ text: String) -> String {
        if text.count <= maxPayloadLength { return text }
        let prefix = String(text.prefix(maxPayloadLength))
        let remaining = text.count - maxPayloadLength
        return "\(prefix)…<truncated \(remaining) chars>"
    }
#else
    static func logRequest(_ request: URLRequest, bodyOverride: Data? = nil, label: String? = nil) {}
    static func logResponse(_ response: URLResponse?, data: Data?, label: String? = nil) {}
    static func logError(_ error: Error, label: String? = nil) {}
    static func logWebSocket(direction: String, context: String, message: String) {}
    static func logWebSocketBinary(direction: String, context: String, size: Int) {}
#endif
}
