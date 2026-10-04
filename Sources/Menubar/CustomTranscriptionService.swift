import Foundation
import CryptoKit
import Security

protocol TranscriptionSecretStoring {
    func read(endpoint: String) throws -> String?
    func write(_ value: String?, endpoint: String) throws
}

struct KeychainTranscriptionSecrets: TranscriptionSecretStoring {
    var service = "build.agora.astation.transcription"
    private func query(_ endpoint: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }
    func read(endpoint: String) throws -> String? {
        var attributes = query(endpoint)
        attributes[kSecReturnData as String] = true; attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.message("The custom-service key could not be read from Keychain (\(status)).")
        }
        return value
    }
    func write(_ value: String?, endpoint: String) throws {
        let base = query(endpoint)
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = base
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(attributes as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw TranscriptionError.message("The custom-service key could not be saved in Keychain (\(status)).") }
        } else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranscriptionError.message("The custom-service key could not be cleared from Keychain (\(status)).")
            }
        }
    }
}

final class NoTranscriptionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CustomTranscriptionHTTP {
    static let maximumResponseBytes = 1_000_000
    static func endpoint(_ value: String) -> URL? {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return url
    }
    static func validate(_ settings: TranscriptionSettings) throws {
        guard endpoint(settings.customEndpoint) != nil else {
            throw TranscriptionError.message("Enter a full HTTPS transcription endpoint without credentials or query parameters. HTTP is allowed only on localhost.")
        }
        guard !settings.customModel.isEmpty, settings.customModel.utf8.count <= 256,
              !settings.customModel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              settings.language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil,
              settings.language.utf8.count <= 32,
              [5, 10, 15].contains(settings.customChunkSeconds) else {
            throw TranscriptionError.message("Enter a model name and choose a 5, 10, or 15 second upload window.")
        }
    }
    static func request(settings: TranscriptionSettings, key: String?, samples: [Float]) throws -> URLRequest {
        try validate(settings)
        guard samples.count <= 24 * 16_000,
              key?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true,
              (key?.utf8.count ?? 0) <= 16_384 else {
            throw TranscriptionError.message("The custom transcription request is invalid.")
        }
        let boundary = "astation-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", settings.customModel)
        field("response_format", "json")
        field("language", settings.language.split(separator: "-").first.map(String.init) ?? "en")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(samples)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint(settings.customEndpoint)!, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw TranscriptionError.message("The custom transcription response is too large.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw TranscriptionError.message("The custom transcription response is too large.")
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(36 + samples.count * 2)); text("WAVEfmt "); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(16_000)); integer(UInt32(32_000))
        integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(samples.count * 2))
        for sample in samples { integer(Int16((Double(sample.isFinite ? max(-1, min(1, sample)) : 0) * 32_767).rounded())) }
        return data
    }
}

actor CustomHTTPTranscriber: LiveTranscribing {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let settings: TranscriptionSettings
    private let key: String?
    private let send: Send
    private var session: URLSession?
    private var callback: (@Sendable (TranscriptSegment) -> Void)?
    private var buffer: SpeechWindowBuffer
    init(settings: TranscriptionSettings, key: String?, send: Send? = nil) {
        self.settings = settings; self.key = key
        buffer = SpeechWindowBuffer(maximumSeconds: settings.customChunkSeconds, partialSeconds: nil)
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: NoTranscriptionRedirects(), delegateQueue: nil)
            self.session = session
            self.send = { try await CustomTranscriptionHTTP.send($0, session: session) }
        }
    }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) throws {
        try CustomTranscriptionHTTP.validate(settings); callback = onSegment
    }
    func consume(_ samples: [Float]) async throws { for window in buffer.append(samples) { try await transcribe(window) } }
    func finish() async throws { if let window = buffer.finish() { try await transcribe(window) } }
    func cancel() { callback = nil; session?.invalidateAndCancel(); session = nil }
    private func transcribe(_ window: SpeechWindowBuffer.Window) async throws {
        try Task.checkCancellation()
        guard callback != nil else { throw CancellationError() }
        let request = try CustomTranscriptionHTTP.request(settings: settings, key: key, samples: window.samples)
        let data: Data, response: URLResponse
        do { (data, response) = try await send(request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw TranscriptionError.message("The custom transcription request failed. Check the endpoint, network, and API key.")
        }
        try Task.checkCancellation()
        guard callback != nil else { throw CancellationError() }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw TranscriptionError.message("The custom transcription service returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Response details are hidden to protect credentials.")
        }
        guard data.count <= CustomTranscriptionHTTP.maximumResponseBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String, text.utf8.count <= 65_536 else {
            throw TranscriptionError.message("The custom service must return JSON with a text field.")
        }
        callback?(TranscriptSegment(id: window.id, sourceID: settings.sourceID, language: settings.language,
            text: text, isFinal: true, offset: window.offset))
    }
}
