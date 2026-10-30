import AtemClient
import Foundation

public enum RemoteRecoveryTransportError: LocalizedError {
    case authenticationRequired, registrationRequired, permissionRequired, accessDenied, unavailable, invalidResponse, insecureURL

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "Authorize your Agora.Build account for this Station, then retry."
        case .registrationRequired: return "This Mac has not registered with the selected Station. Reconnect to the Station, then retry account security setup."
        case .permissionRequired: return "Your Station authorization does not include account recovery access. Authorize Station access again."
        case .accessDenied: return "This Station refused access to the account's recovery data. Your saved setup was retained."
        case .unavailable: return "Account recovery is unavailable on this relay. Your saved operation was retained; retry later."
        case .invalidResponse: return "The relay returned recovery data that could not be verified. Nothing was trusted from this response."
        case .insecureURL: return "Account recovery requires an HTTPS relay, or a local loopback relay."
        }
    }
}

public struct RemoteRecoveryLogPage: Sendable {
    public let head: LogHead
    public let entries: [String]
    public let more: Bool

    public init(head: LogHead, entries: [String], more: Bool) {
        self.head = head; self.entries = entries; self.more = more
    }
}

public enum RemoteRecoveryAppendReply: Sendable {
    case stored
    case conflict(RemoteRecoveryLogPage)
}

public protocol RemoteRecoveryTransport: Sendable {
    func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage
    func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply
    func uploadBackup(genesisHash: String, envelopeJSON: String, signedEntryJSON: String) async throws -> UInt64?
    func backup(log: MembershipLog) async throws -> String
    func hostAccept(genesisHash: String, hostID: String, initFrame: Data) async throws -> Data
}

private final class RecoveryRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// TLS/account login limits storage access. Only the shared verifier grants cryptographic trust.
public final class RemoteRecoveryHTTP: RemoteRecoveryTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String

    public convenience init(relayURL: String, accessToken: @escaping @Sendable () async throws -> String) throws {
        try self.init(relayURL: relayURL, configuration: .ephemeral, accessToken: accessToken)
    }

    init(relayURL: String, configuration: URLSessionConfiguration,
        accessToken: @escaping @Sendable () async throws -> String) throws {
        var components = URLComponents(string: try RemoteRecoveryKit.checkedRelayURL(relayURL))!
        if components.scheme == "wss" { components.scheme = "https" }
        if components.scheme == "ws" { components.scheme = "http" }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host?.lowercased() ?? "")
        guard components.scheme == "https" || (components.scheme == "http" && local), let url = components.url else {
            throw RemoteRecoveryTransportError.insecureURL
        }
        baseURL = url.appendingPathComponent("api/remote/v1/logs", isDirectory: true)
        self.accessToken = accessToken
        let config = configuration
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: RecoveryRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func entries(genesisHash: String, after: UInt64) async throws -> RemoteRecoveryLogPage {
        guard RemoteRecoveryKit.validHash(genesisHash), after <= 9_007_199_254_740_991 else { throw RemoteChannelError.invalidInput }
        var url = URLComponents(url: path(genesisHash, "entries"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "after", value: String(after))]
        let (_, data) = try await perform(url: url.url!, method: "GET")
        return try Self.page(data)
    }

    public func append(genesisHash: String, request: AppendRequest) async throws -> RemoteRecoveryAppendReply {
        guard RemoteRecoveryKit.validHash(genesisHash) else { throw RemoteChannelError.invalidInput }
        let entry = try Self.object(request.entryJson)
        let body = try Self.encode(["entry": entry, "expected": ["seq": request.expected.seq, "hash": request.expected.hash]])
        let (status, data) = try await perform(url: path(genesisHash, "entries"), method: "POST", body: body, allowConflict: true)
        if status == 409 { return .conflict(try Self.page(data)) }
        let reply = try Self.dictionary(data)
        guard let stored = reply["entry"], try signedObjectInfo(json: Self.json(stored)).entryHash == request.entryHash else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return .stored
    }

    /// The entry is the already signed backup intent; this upload never commits that entry.
    public func uploadBackup(genesisHash: String, envelopeJSON: String, signedEntryJSON: String) async throws -> UInt64? {
        let info = try parseKBackup(envelopeJson: envelopeJSON)
        guard RemoteRecoveryKit.validHash(genesisHash), try Self.dictionary(Data(envelopeJSON.utf8))["genesis_hash"] as? String == genesisHash else {
            throw RemoteChannelError.invalidInput
        }
        let authorization = RemoteRecoveryKit.base64URL(Data(signedEntryJSON.utf8))
        guard authorization.utf8.count <= 16_384 else { throw RemoteChannelError.invalidInput }
        let (status, data) = try await perform(url: path(genesisHash, "backups/\(info.blobVersion)"), method: "PUT",
            body: Data(envelopeJSON.utf8), headers: ["X-Astation-Backup-Entry": authorization], allowConflict: true)
        if status == 200 { return nil }
        let body = try Self.dictionary(data)
        guard let value = body["max_occupied"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.uint64Value >= info.blobVersion, value.uint64Value <= 9_007_199_254_740_991,
              value.stringValue == String(value.uint64Value) else { throw RemoteRecoveryTransportError.invalidResponse }
        return value.uint64Value
    }

    public func backup(log: MembershipLog) async throws -> String {
        guard let expected = log.kBackup() else { throw RemoteChannelError.notReady }
        let (_, bytes) = try await perform(url: path(log.genesisHash(), "backups/\(expected.blobVersion)"), method: "GET")
        guard let text = String(data: bytes, encoding: .utf8) else { throw RemoteRecoveryTransportError.invalidResponse }
        let actual = try parseKBackup(envelopeJson: text)
        guard actual == expected else { throw RemoteRecoveryTransportError.invalidResponse }
        return text
    }

    public func hostAccept(genesisHash: String, hostID: String, initFrame: Data) async throws -> Data {
        guard RemoteRecoveryKit.validHash(genesisHash), RemoteRecoveryKit.validID(hostID), initFrame.count <= 65_536 else {
            throw RemoteChannelError.invalidInput
        }
        var url = URLComponents(url: path(genesisHash, "probes"), resolvingAgainstBaseURL: false)!
        url.percentEncodedPath += "/" + hostID.utf8.map { String(format: "%%%02X", $0) }.joined()
        let (_, bytes) = try await perform(url: url.url!, method: "POST", body: initFrame)
        guard bytes.count <= 65_536 else { throw RemoteRecoveryTransportError.invalidResponse }
        _ = try Self.dictionary(bytes)
        return bytes
    }

    private func path(_ genesis: String, _ suffix: String) -> URL {
        baseURL.appendingPathComponent(genesis, isDirectory: true).appendingPathComponent(suffix)
    }

    private func perform(url: URL, method: String, body: Data? = nil, headers: [String: String] = [:],
        allowConflict: Bool = false) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = try await accessToken()
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw RemoteRecoveryTransportError.authenticationRequired
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw RemoteRecoveryTransportError.invalidResponse }
        if response.statusCode == 401 { throw RemoteRecoveryTransportError.authenticationRequired }
        if response.statusCode == 403 {
            var data = Data()
            for try await byte in stream {
                guard data.count < 16_384 else { throw RemoteRecoveryTransportError.invalidResponse }
                data.append(byte)
            }
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            switch code?["code"] as? String {
            case "recovery_creator_not_registered": throw RemoteRecoveryTransportError.registrationRequired
            case "insufficient_scope": throw RemoteRecoveryTransportError.permissionRequired
            default: throw RemoteRecoveryTransportError.accessDenied
            }
        }
        guard response.statusCode == 200 || (allowConflict && response.statusCode == 409) else { throw RemoteRecoveryTransportError.unavailable }
        var data = Data()
        for try await byte in stream {
            guard data.count < 262_144 else { throw RemoteRecoveryTransportError.invalidResponse }
            data.append(byte)
        }
        return (response.statusCode, data)
    }

    private static func page(_ bytes: Data) throws -> RemoteRecoveryLogPage {
        let object = try dictionary(bytes)
        guard let head = object["head"] as? [String: Any], let sequence = head["seq"] as? NSNumber,
              CFGetTypeID(sequence) != CFBooleanGetTypeID(), sequence.uint64Value <= 9_007_199_254_740_991,
              sequence.stringValue == String(sequence.uint64Value), let hash = head["hash"] as? String,
              RemoteRecoveryKit.validHash(hash), let entries = object["entries"] as? [Any], entries.count <= 64,
              object["more"] == nil || (object["more"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return try RemoteRecoveryLogPage(head: LogHead(seq: sequence.uint64Value, hash: hash), entries: entries.map(json),
            more: object["more"] as? Bool ?? false)
    }

    private static func dictionary(_ bytes: Data) throws -> [String: Any] {
        guard let text = String(data: bytes, encoding: .utf8), let value = try object(text) as? [String: Any] else {
            throw RemoteRecoveryTransportError.invalidResponse
        }
        return value
    }
    private static func object(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(canonicalJson(json: text).utf8))
    }
    private static func encode(_ object: Any) throws -> Data { Data(try json(object).utf8) }
    private static func json(_ object: Any) throws -> String {
        try canonicalJson(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
